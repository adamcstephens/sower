{
  lib,
  beamPackages,
  makeWrapper,
}:
beamPackages.mixRelease {
  pname = "sower-tree";
  version = "0.0.1-dev";

  src = ../cmd/sower_tree;

  elixir = beamPackages.elixir_1_16;

  mixNixDeps = import ../cmd/sower_tree/mix.nix { inherit lib beamPackages; };

  postInstall = ''
    cp sower-tree.exs $out/bin/sower-tree
    wrapProgram $out/bin/sower-tree --set ERL_LIBS $out/lib
  '';

  meta.mainProgram = "sower-tree";
}
