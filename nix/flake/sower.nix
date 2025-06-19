{ lib, ... }:
{
  options = {
    sower = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "enable sower features";
        default = true;
      };

      jobs = {
        checks.enable = lib.mkEnableOption "building checks";
        packages.enable = lib.mkEnableOption "building packages without services";
        services.enable = lib.mkEnableOption "building packages with services";
      };
    };
  };

  config = {
    sower.jobs = {
      services.enable = lib.mkDefault true;
    };
  };
}
