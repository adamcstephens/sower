{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower;
  toml = pkgs.formats.toml { };
  tomlType = toml.type;
in
{
  options = {
    services.sower = {
      enable = lib.mkEnableOption "Sower agent";

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
                "nixos"
                "home-manager"
                "nix-darwin"
              ];
              default = "home-manager";
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

    systemd.user.services.sower = {
      Service = {
        Environment = [ "PATH=${lib.makeBinPath [ pkgs.nix ]}" ];
        ExecStart = "${lib.getExe cfg.package} tree upgrade";
      };
    };

    systemd.user.timers.sower = {
      Install.WantedBy = [ "timers.target" ];

      Timer = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    xdg.configFile."sower/config.toml".source = lib.mkIf (cfg.config != null) (
      toml.generate "sower-config.toml" cfg.config
    );
  };
}
