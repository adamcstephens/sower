{ inputs, lib, ... }:
{
  imports = [
    ./sower.nix
  ];

  flake.flakeModules.sower = ./sower.nix;
  flake.lib = import ../sowerlib.nix { inherit inputs lib; };
}
