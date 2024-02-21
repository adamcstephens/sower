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

  postBuild = ''
    mix escript.build --no-deps-check
  '';

  postInstall = ''
    cp sower_tree $out/bin/sower-tree
    wrapProgram $out/bin/sower-tree --set ERL_LIBS $out/lib --prefix PATH : ${
      lib.makeBinPath [ beamPackages.erlang ]
    }
  '';

  meta.mainProgram = "sower-tree";
}
