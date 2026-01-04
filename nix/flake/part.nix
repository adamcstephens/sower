{
  inputs,
  lib,
  self,
  ...
}:
{
  imports = [
    ./sower.nix
  ];

  flake = {
    lib = import ../sowerlib.nix { inherit inputs lib; };

    flakeModules.sower = ./sower.nix;
    homeModules.sower = ../home/module.nix;
    nixosModules.sower = ../nixos/module.nix;
  };

  flake.nixosConfigurations = {
    example = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        "${inputs.nixpkgs}/nixos/maintainers/scripts/incus/incus-container-image.nix"
        { system.stateVersion = "25.11"; }
        { sower.seed.meta.broken = true; }
        self.nixosModules.sower
      ];
    };

    example2 = inputs.nixpkgs.lib.nixosSystem {
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
}
