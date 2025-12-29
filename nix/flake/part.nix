{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  imports = [
    ./sowerjobs.nix
  ];

  options = {
    sower = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "enable sower features";
        default = true;
      };

      jobs = {
        checks.enable = lib.mkEnableOption "building checks";
        home-manager.enable = lib.mkEnableOption "building home-manager configurations";
        nixos.enable = lib.mkEnableOption "building nixos configurations";
        packages.enable = lib.mkEnableOption "building packages without services";
        services.enable = lib.mkEnableOption "building packages with services";
      };
    };
  };

  config = {
    flake.nixosConfigurations = {
      example = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${inputs.nixpkgs}/nixos/maintainers/scripts/incus/incus-container-image.nix"
          { system.stateVersion = "25.11"; }
        ];
      };

      example-aarch64 = inputs.nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          "${inputs.nixpkgs}/nixos/maintainers/scripts/incus/incus-container-image.nix"
          { system.stateVersion = "25.11"; }
        ];
      };
    };

    sower.jobs = {
      home-manager.enable = lib.mkDefault true;
      nixos.enable = lib.mkDefault true;
      packages.enable = lib.mkDefault true;
      services.enable = lib.mkDefault true;
    };

    perSystem =
      {
        self',
        system,
        ...
      }:
      let
        cfg = config.sower.jobs;
        is_service = builtins.hasAttr "sowerServices";

        checks = lib.mapAttrs' (n: v: lib.nameValuePair "check/${n}" v) self'.checks;
        nixos = lib.pipe self.nixosConfigurations [
          (lib.filterAttrs (_: nixosConfig: nixosConfig.pkgs.stdenv.hostPlatform.system == system))
          (lib.mapAttrs' (
            name: nixosConfig:
            lib.nameValuePair "nixos/${name}" (
              nixosConfig.config.system.build.toplevel.overrideAttrs (old: {
                meta = (old.meta or { }) // {
                  sower = {
                    inherit name;
                    seed_type = "nixos";
                  };
                };
              })
            )
          ))
        ];
        home-manager = lib.pipe (self.homeConfigurations or { }) [
          (lib.filterAttrs (_: homeConfig: homeConfig.pkgs.stdenv.hostPlatform.system == system))
          (lib.mapAttrs' (
            name: homeConfig:
            lib.nameValuePair "nixos/${name}" (
              homeConfig.activationPackage.overrideAttrs (old: {
                meta = (old.meta or { }) // {
                  sower = {
                    inherit name;
                    seed_type = "home-manager";
                  };
                };
              })
            )
          ))
        ];
        packages = lib.pipe self'.packages [
          (lib.filterAttrs (_: v: !(is_service v)))
          (lib.mapAttrs' (n: v: lib.nameValuePair "package/${n}" v))
        ];
        services = lib.pipe self'.packages [
          (lib.filterAttrs (_: v: (is_service v)))
          (lib.mapAttrs' (n: v: lib.nameValuePair "package/${n}" v))
        ];
      in
      {

        sowerJobs = lib.mkMerge [
          (lib.mkIf cfg.checks.enable checks)
          (lib.mkIf cfg.home-manager.enable home-manager)
          (lib.mkIf cfg.nixos.enable nixos)
          (lib.mkIf cfg.packages.enable packages)
          (lib.mkIf cfg.services.enable services)
        ];
      };
  };
}
