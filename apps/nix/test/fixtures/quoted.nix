{ }:
let
  lock = builtins.fromJSON (builtins.readFile ../../../../flake.lock);
  nixpkgs = builtins.fetchTree lock.nodes.nixpkgs.locked;
  pkgs = import nixpkgs { };
  job = name: (pkgs.runCommand "quoted-selector-${name}" { } ''
    mkdir --parents "$out"
    echo ${name} > "$out/selected"
  '') // { meta = throw "selection must not force metadata"; };
in
{
  "seed/host" = job "plain";
  "seed/host.example" = job "dotted";
  "seed/quote\"back\\\${literal}.example" = job "escaped";
  nested."group.with.dot"."seed/host.example" = job "nested";
}
