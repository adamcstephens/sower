{ }:
let
  lock = builtins.fromJSON (builtins.readFile ../../../../flake.lock);
  nixpkgs = builtins.fetchTree lock.nodes.nixpkgs.locked;
  pkgs = import nixpkgs { };
  sowerLib = import ../../../../nix/sowerlib.nix {
    inputs = { };
    lib = pkgs.lib;
  };
  target = pkgs.runCommand "metadata-independent-target" { } ''
    mkdir --parents "$out"
    echo ready > "$out/ready"
  '';
  seed = sowerLib.mkSeed {
    inherit pkgs target;
    name = "manifest-host";
    type = "nixos";
    tags.origin = "manifest";
  };
in
{
  "seed/host" = seed // { meta = throw "evaluation must not force seed metadata"; };
  "package/tool" = target // { meta = throw "evaluation must not force ordinary metadata"; };
}
