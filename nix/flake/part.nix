{ inputs, lib, ... }:
{
  imports = [
    ./sower.nix
  ];

  flake.flakeModules.sower = ./sower.nix;
  flake.lib = import ../sowerlib.nix { inherit inputs lib; };

  flake.nixosConfigurations = {
    example = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        "${inputs.nixpkgs}/nixos/maintainers/scripts/incus/incus-container-image.nix"
        { system.stateVersion = "25.11"; }
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
