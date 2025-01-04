{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.client;
  json = pkgs.formats.json { };
  jsonType = json.type;
in
{
  options = {
    services.sower.client = {
      enable = lib.mkEnableOption "Sower client";

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
            api-token-file = lib.mkOption {
              type = lib.types.str;
              description = "path to API token file. This is a secret so should not be in the nix store";
            };

            seed = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "seed name";
                default = config.networking.hostName;
              };

              type = lib.mkOption {
                type = lib.types.enum [
                  "home-manager"
                  "nix-darwin"
                  "nixos"
                ];
                default = "nixos";
              };
            };
          };
        };
        description = "Sower configuration file";
        default = null;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."sower/client.json".source = lib.mkIf (cfg.settings != null) (
      json.generate "sower-client.json" (
        cfg.settings // (lib.optionalAttrs cfg.autoreboot { reboot = true; })
      )
    );

    environment.systemPackages = [ cfg.package ];

    systemd.services.sower-client = {
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];
      path = [ config.nix.package ];

      environment = {
        SOWER_CONFIG_FILE = "/etc/sower/client.json";
      };

      # avoid restarting mid-switch
      restartIfChanged = false;

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} seed upgrade ${lib.optionalString cfg.autoreboot "--yes"}";
        Type = "oneshot";
        LoadCredential = cfg.credentials;
      };
    };

    systemd.timers.sower-client = {
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
      };
    };
  };
}
