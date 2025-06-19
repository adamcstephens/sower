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
  jsonConfig = json.generate "sower-client.json" (
    cfg.settings // (lib.optionalAttrs cfg.autoreboot { reboot = true; })
  );
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

            services.services = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "services to be managed by client";
              default = [ ];
            };
          };
        };
        description = "Sower configuration file";
        default = null;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.extraSystemdUnitPaths = lib.optionals (cfg.settings.services.services != [ ]) [
      "/etc/sower/systemd/system"
    ];

    environment.etc."sower/client.json".source = lib.mkIf (cfg.settings != null) jsonConfig;

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
        ExecStart =
          [
            "${lib.getExe cfg.package} seed upgrade ${lib.optionalString cfg.autoreboot "--yes"}"
          ]
          ++ lib.optionals (cfg.settings.services.services != [ ]) [
            "${lib.getExe cfg.package} services upgrade"
          ];
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

    systemd.tmpfiles.rules = lib.optionals (cfg.settings.services.services != [ ]) [
      "d /etc/sower 0755 root root"
      "L /etc/sower/systemd - - - - /nix/var/nix/profiles/sower/services-units/systemd"
    ];
  };
}
