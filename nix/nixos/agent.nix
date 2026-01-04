{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.agent;
  json = pkgs.formats.json { };
  jsonType = json.type;
  jsonConfig = json.generate "sower-client.json" (
    cfg.settings // (lib.optionalAttrs cfg.autoreboot { reboot = true; })
  );

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
    boot.extraSystemdUnitPaths = lib.optionals manageServices [
      "/etc/sower/systemd/system"
    ];

    environment.etc."sower/client.json".source = lib.mkIf (cfg.settings != null) jsonConfig;

    environment.systemPackages = [ cfg.package ];

    systemd.services.sower-agent = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optionals config.services.sower.server.enable [ "sower.service" ];
      requires = [
        "network-online.target"
      ]
      ++ lib.optionals config.services.sower.server.enable [ "sower.service" ];
      path = [ config.nix.package ];

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

        DynamicUser = true;
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
      };
    };

    systemd.tmpfiles.rules = lib.optionals manageServices [
      "d /etc/sower 0755 root root"
      "L /etc/sower/systemd - - - - /nix/var/nix/profiles/sower/services-units/systemd"
    ];
  };
}
