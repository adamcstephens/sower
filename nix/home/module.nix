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

      package = lib.mkOption { type = lib.types.package; };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        description = "OnCalendar for systemd timer on linux. See https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#Calendar%20Events";
        default = "daily";
      };

      config = lib.mkOption {
        type = lib.types.submodule {
          freeformType = jsonType;

          options = {
            seed = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "seed name";
                default = config.home.username;
              };

              type = lib.mkOption {
                type = lib.types.enum [
                  "home-manager"
                  "nix-darwin"
                  "nixos"
                ];
                default = "home-manager";
              };
            };
          };
        };
        description = "Sower configuration file";
        default = null;
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.package ];

        xdg.configFile."sower/client.json".source = lib.mkIf (cfg.config != null) (
          json.generate "sower-client.json" cfg.config
        );
      }

      (lib.mkIf pkgs.stdenv.isLinux {
        systemd.user.services.sower-client = {
          Service = {
            Environment = [
              # prefer nix from the system
              "PATH=/run/current-system/sw/bin:${lib.makeBinPath [ config.nix.package ]}"
              "SOWER_CONFIG_FILE=%E/sower/client.json"
            ];
            ExecStart = "${lib.getExe cfg.package} seed upgrade";
            Type = "oneshot";
          };

          Unit = {
            # For sd-switch users, this prevents killing sower mid-upgrade
            X-SwitchMethod = "keep-old";
          };
        };

        systemd.user.timers.sower-client = {
          Install.WantedBy = [ "timers.target" ];

          Timer = {
            OnCalendar = cfg.onCalendar;
            Persistent = true;
          };
        };
      })

      (lib.mkIf pkgs.stdenv.isDarwin {
        launchd = {
          agents.sower-client = {
            enable = true;
            config = {
              KeepAlive = false;
              ProgramArguments = [
                (lib.getExe cfg.package)
                "seed"
                "upgrade"
              ];
              StartCalendarInterval = [
                {
                  Hour = 1;
                  Minute = 0;
                }
              ];
              StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/sower-client-out.log";
              StandardOutPath = "${config.home.homeDirectory}/Library/Logs/sower-client-err.log";
            };
          };
        };
      })
    ]
  );
}
