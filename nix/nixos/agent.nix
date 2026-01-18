{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.agent;
  activatorCfg = config.services.sower.activator;
  json = pkgs.formats.json { };
  jsonType = json.type;

  # Build agent settings, optionally including activator socket path
  agentSettings =
    cfg.settings
    // (lib.optionalAttrs cfg.autoreboot { reboot = true; })
    // (lib.optionalAttrs activatorCfg.enable { activator_socket = activatorCfg.socketPath; });

  jsonConfig = json.generate "sower-client.json" agentSettings;

  # TODO re-enable services support
  manageServices = false;

  adminScript = pkgs.writeShellApplication {
    name = "sower-server";

    text =
      (lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: val: ''
          ${name}="${val}"
          export ${name}
        '') cfg.environment
      ))
      + ''
        RELEASE_COOKIE=$(cat release-cookie)
        export RELEASE_COOKIE
        exec ${lib.getExe cfg.package} "$@"
      '';
  };
in
{
  options = {
    services.sower.agent = {
      enable = lib.mkEnableOption "Sower agent";

      autoreboot = lib.mkEnableOption "automatic rebooting";

      credentials = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "systemd credentials";
        default = [ ];
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        description = "OnCalendar for systemd timer on linux. See https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#Calendar%20Events";
        default = "daily";
      };

      package = lib.mkOption { type = lib.types.package; };

      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = jsonType;

          options = {
          };
        };
        description = "Sower client (agent and cli) configuration file";
        default = null;
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
      allowedGroups = [ "sower-agent" ];
    };

    systemd.services.sower-agent = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optionals config.services.sower.server.enable [ "sower.service" ]
      ++ lib.optionals activatorCfg.enable [ "sower-activator.service" ];
      requires = [
        "network-online.target"
      ];
      wants =
        lib.optionals activatorCfg.enable [ "sower-activator.service" ]
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
        # erlexec needs a shell
        SHELL = lib.getExe pkgs.bash;
        SOWER_CONFIG_FILE = "/etc/sower/client.json";
        # load code on demand
        RELEASE_MODE = "interactive";
      };

      # reload is an async notification to the agent
      reloadIfChanged = true;
      # avoid restarting mid-switch
      restartIfChanged = false;
      restartTriggers = [
        config.environment.etc."sower/client.json".source
      ];

      serviceConfig = {
        Type = "notify";
        WatchdogSec = "10s";
        Restart = lib.mkDefault "always";
        RestartSec = "5";

        LoadCredential = cfg.credentials;

        # DynamicUser = true;
        ProtectSystem = "full";
        ProtectHome = "tmpfs";
        PrivateTmp = true;
        NoNewPrivileges = false;
        SupplementaryGroups = lib.optionals activatorCfg.enable [ activatorCfg.socketGroup ];
        User = "sower-agent";
        Group = "sower-agent";
        BindPaths = lib.optionals activatorCfg.enable [ activatorCfg.socketPath ];

        StateDirectory = "sower-agent";
        WorkingDirectory = "%S/sower-agent";

        ExecStartPre = pkgs.writeShellScript "sower-agentinit-secrets" ''
          if [ ! -e release-cookie ]; then
            echo "Generating release cookie"
            ${lib.getExe pkgs.openssl} rand -hex 48 > release-cookie
          fi
        '';
        ExecStart = pkgs.writeShellScript "sower-agent-start" ''
          RELEASE_COOKIE=$(cat release-cookie)
          export RELEASE_COOKIE

          exec ${lib.getExe cfg.package} start
        '';
        ExecStop = pkgs.writeShellScript "sower-agent-stop" ''
          RELEASE_COOKIE=$(cat release-cookie)
          export RELEASE_COOKIE

          exec ${lib.getExe cfg.package} stop
        '';
        # Request reload via RPC - the agent will restart itself at end of deployment
        ExecReload = pkgs.writeShellScript "sower-agent-reload" ''
          RELEASE_COOKIE=$(cat release-cookie)
          export RELEASE_COOKIE

          ${lib.getExe cfg.package} rpc "SowerAgent.request_reload()"
        '';

        MemoryAccounting = true;
        MemoryMax = "200M";
      };
    };

    security.sudo.extraRules = lib.mkIf (!activatorCfg.enable) [
      {
        users = [ "sower-agent" ];
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
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          # old dbus may not support system_unit, debugging is available if needed
          # if (action.id == "org.freedesktop.systemd1.manage-units") {
          #   polkit.log("sower polkit: unit=" + action.lookup("unit") +
          #     " verb=" + action.lookup("verb") +
          #     " user=" + subject.user +
          #     " system_unit=" + subject.system_unit +
          #     " pid=" + subject.pid);
          # }

          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "sower-agent.service" &&
              action.lookup("verb") == "restart" &&
              subject.system_unit == "sower-agent.service") {
            return polkit.Result.YES;
          }
        });
      '';
    };

    systemd.tmpfiles.rules = lib.optionals manageServices [
      "d /etc/sower 0755 root root"
      "L /etc/sower/systemd - - - - /nix/var/nix/profiles/sower/services-units/systemd"
    ];

    users.groups.sower-agent = { };
    users.users.sower-agent = {
      isSystemUser = true;
      group = "sower-agent";
    };
  };
}
