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
        assertion = !config.security.sudo-rs.enable;
        messages = "sudo-rs is not supported";
      }
    ];

    boot.extraSystemdUnitPaths = lib.optionals manageServices [
      "/etc/sower/systemd/system"
    ];

    environment.etc."sower/client.json".source = lib.mkIf (cfg.settings != null) jsonConfig;

    environment.systemPackages = [ cfg.package ];

    services.sower.activator.enable = lib.mkDefault true;

    systemd.services.sower-agent = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optionals config.services.sower.server.enable [ "sower.service" ]
      ++ lib.optionals activatorCfg.enable [ "sower-activator.service" ];
      requires = [
        "network-online.target"
      ]
      ++ lib.optionals config.services.sower.server.enable [ "sower.service" ]
      ++ lib.optionals activatorCfg.enable [ "sower-activator.service" ];
      path = [
        "/run/wrappers"
        config.nix.package
      ]
      ++ lib.optionals activatorCfg.enable [
        activatorCfg.package
      ];

      environment = {
        SHELL = lib.getExe pkgs.bash;
        SOWER_CONFIG_FILE = "/etc/sower/client.json";
      };

      # avoid restarting mid-switch
      restartIfChanged = false;

      serviceConfig = {
        Type = "notify";
        WatchdogSec = "10s";
        Restart = lib.mkDefault "on-failure";

        LoadCredential = cfg.credentials;

        # DynamicUser = true;
        ProtectSystem = "full";
        ProtectHome = "tmpfs";
        PrivateTmp = true;
        NoNewPrivileges = false;
        SupplementaryGroups = [ "wheel" ];
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
        ExecStop = "${lib.getExe cfg.package} stop";

        MemoryAccounting = true;
        MemoryMax = "200M";
      };
    };

    # Only add sudo rule when activator socket mode is not enabled
    security.sudo.extraRules = lib.mkIf (!activatorCfg.enable) [
      {
        groups = [ "wheel" ];
        commands = [
          {
            command = lib.getExe activatorCfg.package;
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "sower-agent.service" &&
              action.lookup("verb") == "reload" &&
              subject.system_unit == "sower-agent.service") &&
              subject.user == "sower-agent") {
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
