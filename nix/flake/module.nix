{ config, lib, ... }:
{
  imports = [
    ./sower.nix
    ./sowerjobs.nix
  ];

  perSystem =
    {
      self',
      ...
    }:
    let
      cfg = config.sower.jobs;
      is_service = builtins.hasAttr "sowerServices";
      checks = lib.mapAttrs' (n: v: lib.nameValuePair "check/${n}" v) self'.checks;
      packages = lib.mapAttrs' (n: v: lib.nameValuePair "package/${n}" v) (
        lib.filterAttrs (_: v: !(is_service v)) self'.packages
      );
      services = lib.mapAttrs' (n: v: lib.nameValuePair "service/${n}" v) (
        lib.filterAttrs (_: v: is_service v) self'.packages
      );
    in
    {

      sowerJobs = lib.mkMerge [
        (lib.mkIf cfg.checks.enable checks)
        (lib.mkIf cfg.packages.enable packages)
        (lib.mkIf cfg.services.enable services)
      ];
    };
}
