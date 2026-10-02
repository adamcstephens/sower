{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  cfg = config.sower;
  sowerLib = import ../sowerlib.nix { inherit inputs lib; };
in
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

      checks.enable = lib.mkEnableOption "building checks";
      devshells.enable = lib.mkEnableOption "building devshells";
      home-manager.enable = lib.mkEnableOption "building home-manager configurations";
      nixos.enable = lib.mkEnableOption "building nixos configurations";
      packages.enable = lib.mkEnableOption "building packages without services";
    };
  };

  config = lib.mkIf cfg.enable {
    sower = {
      home-manager.enable = lib.mkDefault true;
      nixos.enable = lib.mkDefault true;
      packages.enable = lib.mkDefault true;
    };

    flake.sowerJobs = lib.mkMerge [
      (lib.mkIf cfg.checks.enable (sowerLib.prefixFlakeSystemOutputs "checks" (self.checks or { })))
      (lib.mkIf cfg.devshells.enable (
        sowerLib.prefixFlakeSystemOutputs "devshells" (self.devShells or { })
      ))
      (lib.mkIf cfg.nixos.enable (sowerLib.genNixosPackages (self.nixosConfigurations or { })))
      (lib.mkIf cfg.home-manager.enable (
        sowerLib.genHomeManagerPackages (self.homeConfigurations or { })
      ))
      (lib.mkIf cfg.packages.enable (sowerLib.prefixFlakeSystemOutputs "packages" (self.packages or { })))
    ];
  };
}
