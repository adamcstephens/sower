{ }:
let
  lock = builtins.fromJSON (builtins.readFile ../../../../flake.lock);
  nixpkgs = builtins.fetchTree lock.nodes.nixpkgs.locked;
  pkgs = import nixpkgs { };
  target = pkgs.runCommand "metadata-independent-target" { } ''
    mkdir --parents "$out"
    echo ready > "$out/ready"
  '';
  seed = pkgs.writeTextDir "seed.json" (builtins.toJSON {
    version = 1;
    name = "manifest-host";
    seed_type = "nixos";
    artifact = "${target}";
    tags.origin = "manifest";
  });
in
{
  "seed/host" = seed // { meta = throw "evaluation must not force seed metadata"; };
  "package/tool" = target // { meta = throw "evaluation must not force ordinary metadata"; };
}
