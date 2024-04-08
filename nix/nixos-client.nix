{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.client;
  toml = pkgs.formats.toml { };
  tomlType = toml.type;
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

      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = tomlType;

          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL to Sower, e.g. https://mysower.org/";
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
        description = "Sower configuration file";
        default = null;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."sower/config.toml".source = lib.mkIf (cfg.settings != null) (
      toml.generate "sower-config.toml" cfg.settings
    );

    systemd.services.sower-client = {
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];
      path = [ pkgs.nix ];

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} tree upgrade";
        Type = "oneshot";
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
