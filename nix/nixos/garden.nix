{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.garden;
  activatorCfg = config.services.sower.activator;
  json = pkgs.formats.json { };
  jsonType = json.type;

  # Build garden settings, optionally including activator socket path
  gardenSettings =
    cfg.settings
    // (lib.optionalAttrs activatorCfg.enable { activator_socket = activatorCfg.socketPath; });

  jsonConfig = json.generate "sower-client.json" gardenSettings;

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

  stopScript = pkgs.writeShellApplication {
    name = "sower-garden-stop";
    text = ''
      RELEASE_COOKIE=$(cat release-cookie)
      export RELEASE_COOKIE
      PID=$(${lib.getExe cfg.package} pid)

      exec ${lib.getExe cfg.package} stop

      while [ -d "/proc/$PID" ]; do sleep 1; done
    '';
  };

  reloadScript = pkgs.writeShellApplication {
    name = "sower-garden-reload";
    text = ''
      RELEASE_COOKIE=$(cat release-cookie)
      export RELEASE_COOKIE

      ${lib.getExe cfg.package} rpc "Garden.request_reload()"
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

          options = { };
        };
        description = "Sower client (garden and cli) configuration file";
        default = { };
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

    environment.systemPackages = [
      adminScript
    ];

    services.sower.activator = {
      enable = lib.mkDefault true;
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
      ];

      environment = {
        # load code on demand, reduces memory requirement
        RELEASE_MODE = "interactive";

        SOWER_CONFIG_FILE = "/etc/sower/client.json";
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
        ];
        SupplementaryGroups = lib.optionals activatorCfg.enable [ activatorCfg.socketGroup ];
        User = "sower-garden";
        Group = "sower-garden";
        BindPaths = lib.optionals activatorCfg.enable [ activatorCfg.socketPath ];
        UMask = "0077";

        StateDirectory = "sower-garden";
        StateDirectoryMode = "0700";
        WorkingDirectory = "%S/sower-garden";

        ExecStartPre = [
          (lib.getExe secretsScript)
        ];
        ExecStart = lib.getExe startScript;
        ExecStop = lib.getExe stopScript;
        # Request reload via RPC - the garden will restart itself at end of deployment
        ExecReload = lib.getExe reloadScript;

        MemoryAccounting = true;
        MemoryMax = "200M";
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
      debug = true;
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
