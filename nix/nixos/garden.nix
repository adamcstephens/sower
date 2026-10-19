{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.garden;
  activatorCfg = config.services.sower.activator;
  builderEnabled = cfg.settings.builder.enable;
  builderNetworkEnabled = builderEnabled && activatorCfg.network.enable;
  json = pkgs.formats.json { };
  jsonType = json.type;

  # The garden BEAM binds this admin socket itself (no .socket unit); the dir is
  # provided by RuntimeDirectory below.
  adminSocketPath = "/run/sower-garden/admin.sock";

  # Build garden settings, optionally including activator socket path
  gardenSettings =
    builtins.removeAttrs cfg.settings [
      "builder"
      "builder_network"
    ]
    // {
      admin_socket = adminSocketPath;
    }
    // lib.optionalAttrs builderEnabled {
      builder = true;
      builder_network = builderNetworkEnabled;
    }
    // (lib.optionalAttrs activatorCfg.enable { activator_socket = activatorCfg.socketPath; });

  jsonConfig = json.generate "sower-client.json" gardenSettings;
  networkCleanup = "+${lib.getExe activatorCfg.package} activator --network-policy ${activatorCfg.network.policyFile} --network-cleanup --network-instance sower-garden.service";

  # TODO re-enable services support
  manageServices = false;

  adminScript = pkgs.writeShellApplication {
    name = "sower-garden";

    text =
      (lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: val: ''
          ${name}="${val}"
          export ${name}
        '') config.systemd.services.sower-garden.environment
      ))
      + ''
        RELEASE_COOKIE=$(cat /var/lib/sower-garden/release-cookie)
        export RELEASE_COOKIE
        exec ${lib.getExe cfg.package} "$@"
      '';
  };

  secretsScript = pkgs.writeShellApplication {
    name = "sower-garden-init-secrets";
    runtimeInputs = [ pkgs.openssl ];
    text = ''
      if [ ! -e release-cookie ]; then
        echo "Generating release cookie"
        openssl rand -hex 48 > release-cookie
      fi
    '';
  };

  startScript = pkgs.writeShellApplication {
    name = "sower-garden-start";
    text = ''
      RELEASE_COOKIE=$(cat release-cookie)
      export RELEASE_COOKIE

      exec ${lib.getExe cfg.package} start
    '';
  };
in
{
  options = {
    services.sower.garden = {
      enable = lib.mkEnableOption "Sower garden";

      package = lib.mkOption { type = lib.types.package; };

      accessTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        description = "path to access token";
        default = null;
      };

      credentials = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "systemd credentials";
        default = [ ];
      };

      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = jsonType;

          options.builder.enable = lib.mkEnableOption "isolated builder command execution";
        };
        description = "Sower client (garden and cli) configuration file";
        default = { };
      };

      distribution = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable Erlang distribution for the garden.

          When disabled (default), the garden runs without distribution.
          Lifecycle is driven by systemd signals (SIGTERM for stop, SIGHUP
          for reload); release CLI subcommands that need distribution
          (rpc, remote, pid, stop) will not work, and the `sower-garden`
          admin wrapper is not installed.

          Enable to allow ad-hoc RPC into the running BEAM. Multiple
          gardens on one host require distinct RELEASE_NODE values to
          avoid collisions on epmd.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = activatorCfg.enable || !config.security.sudo-rs.enable;
        message = "sudo-rs is not supported";
      }
    ];

    boot.extraSystemdUnitPaths = lib.optionals manageServices [
      "/etc/sower/systemd/system"
    ];

    environment.etc."sower/client.json".source = lib.mkIf (cfg.settings != null) jsonConfig;

    environment.systemPackages = lib.optionals cfg.distribution [
      adminScript
    ];

    services.sower.activator = {
      enable = lib.mkDefault true;
      network.enable = lib.mkDefault builderEnabled;
      allowedGroups = [ "sower-garden" ];
    };

    systemd.services.sower-garden = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optionals config.services.sower.server.enable [ "sower.service" ]
      ++ lib.optionals activatorCfg.enable [ "sower-activator.socket" ];
      requires = [
        "network-online.target"
      ];
      wants =
        lib.optionals activatorCfg.enable [ "sower-activator.socket" ]
        ++ lib.optionals config.services.sower.server.enable [ "sower.service" ];

      path = [
        config.nix.package
      ]
      ++ lib.optionals (!activatorCfg.enable) [
        "/run/wrappers"
      ]
      ++ lib.optionals activatorCfg.enable [
        activatorCfg.package
      ]
      ++ lib.optionals builderNetworkEnabled [
        pkgs.iproute2
        pkgs.nftables
        pkgs.conntrack-tools
        config.systemd.package
        pkgs.coreutils
      ];

      environment = {
        # load code on demand, reduces memory requirement
        RELEASE_MODE = "interactive";

        SOWER_CONFIG_FILE = "/etc/sower/client.json";
      }
      // lib.optionalAttrs (!cfg.distribution) {
        RELEASE_DISTRIBUTION = "none";
        # the release start script reads RELEASE_COOKIE unconditionally;
        # with distribution off the value is unused but must be set so
        # the script doesn't try to read a non-existent releases/COOKIE.
        RELEASE_COOKIE = "disabled";
      }
      // lib.optionalAttrs (cfg.accessTokenFile != null) {
        SOWER_ACCESS_TOKEN_FILE = cfg.accessTokenFile;
      };

      # reload is an async notification to the garden
      reloadIfChanged = true;
      # avoid restarting mid-switch
      restartIfChanged = false;
      restartTriggers = [
        config.environment.etc."sower/client.json".source
      ];

      serviceConfig = {
        Type = "notify";
        WatchdogSec = "10s";
        KillMode = "control-group";

        # automatic recovery is preferred
        Restart = lib.mkDefault "always";
        RestartSec = "5";
        # back off to reduce load from beam startups
        RestartMaxDelaySec = "120s";
        RestartSteps = "7";

        LoadCredential = cfg.credentials;

        # DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        PrivateDevices = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RemoveIPC = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
        # omit @privileged and @resources — BEAM VM may need them
        SystemCallFilter = [
          "~@mount"
          "~@reboot"
          "~@swap"
          "~@obsolete"
          "~@clock"
          "~@cpu-emulation"
          "~@debug"
          "~@module"
          "~@raw-io"
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ]
        ++ lib.optionals builderNetworkEnabled [ "AF_NETLINK" ];
        SupplementaryGroups =
          lib.optionals activatorCfg.enable [ activatorCfg.socketGroup ]
          ++ lib.optionals builderEnabled [ "kvm" ];
        User = "sower-garden";
        Group = "sower-garden";
        BindPaths =
          lib.optionals activatorCfg.enable [ activatorCfg.socketPath ]
          ++ lib.optionals builderEnabled [ "/dev/kvm" ]
          ++ lib.optionals builderNetworkEnabled [ "/dev/net/tun" ];
        DeviceAllow =
          lib.optionals builderEnabled [ "/dev/kvm rw" ]
          ++ lib.optionals builderNetworkEnabled [ "/dev/net/tun rw" ];
        ReadWritePaths = lib.optionals builderNetworkEnabled [
          activatorCfg.network.stateDirectory
          "/run/sower-network-ownership"
        ];
        UMask = "0077";

        StateDirectory = "sower-garden";
        StateDirectoryMode = "0700";
        WorkingDirectory = "%S/sower-garden";

        # Dir for the BEAM-bound admin socket (/run/sower-garden/admin.sock).
        # Group-traversable so sower-garden members can reach the socket.
        RuntimeDirectory = "sower-garden";
        RuntimeDirectoryMode = "0750";

        ExecStartPre =
          lib.optionals cfg.distribution [
            (lib.getExe secretsScript)
          ]
          ++ lib.optionals builderNetworkEnabled [ networkCleanup ];
        ExecStopPost = lib.optionals builderNetworkEnabled [ networkCleanup ];
        ExecStart = if cfg.distribution then lib.getExe startScript else "${lib.getExe cfg.package} start";
        # SIGHUP triggers Garden.SignalHandler; the garden restarts itself at
        # end of the deployment in progress.
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";

        MemoryAccounting = true;
        MemoryMax = lib.mkDefault (if builderEnabled then "infinity" else "200M");
      };
    };

    security.sudo.extraRules = lib.mkIf (!activatorCfg.enable) [
      {
        users = [ "sower-garden" ];
        commands = [
          {
            command = lib.getExe activatorCfg.package;
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # TODO this should really be guarded with an assertion
    # to avoid setting this on users unaware
    # and it seems to need a boot switch to apply cleanly
    services.dbus.implementation = "broker";

    security.polkit = {
      enable = true;
      extraConfig = # javascript
        ''
          polkit.addRule(function(action, subject) {
            // old dbus may not support system_unit, debugging is available if needed
            // if (action.id == "org.freedesktop.systemd1.manage-units") {
            //   polkit.log("sower polkit: unit=" + action.lookup("unit") +
            //     " verb=" + action.lookup("verb") +
            //     " user=" + subject.user +
            //     " system_unit=" + subject.system_unit +
            //     " pid=" + subject.pid);
            // }

            if (action.id == "org.freedesktop.systemd1.manage-units" &&
                action.lookup("unit") == "sower-garden.service" &&
                action.lookup("verb") == "restart" &&
                subject.system_unit == "sower-garden.service") {
              return polkit.Result.YES;
            }
          });
        '';
    };

    systemd.tmpfiles.rules = lib.optionals manageServices [
      "d /etc/sower 0755 root root"
      "L /etc/sower/systemd - - - - /nix/var/nix/profiles/sower/services-units/systemd"
    ];

    users.groups.sower-garden = { };
    users.users.sower-garden = {
      isSystemUser = true;
      group = "sower-garden";
    };
  };
}
