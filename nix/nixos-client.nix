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

      config = lib.mkOption {
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
    assertions = [
      {
        assertion = cfg.config.url != null;
        message = "Sower URL is required";
      }
    ];

    environment.etc."sower/config.toml".source = lib.mkIf (cfg.config != null) (
      toml.generate "sower-config.toml" cfg.config
    );

    systemd.services.sower-client = {
      path = [ pkgs.nix ];

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} tree upgrade --reboot --yes";
        Type = "oneshot";
      };
    };

    systemd.timers.sower-client = {
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
