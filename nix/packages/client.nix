{
  beamPackages,
  callPackages,
  lib,
  version,
}:

beamPackages.mixRelease {
  pname = "sower-client";
  inherit version;

  src = lib.fileset.toSource {
    root = ../../client-elixir;
    fileset = lib.fileset.unions [
      ../../client-elixir
    ];
  };

  mixNixDeps = callPackages ../../client-elixir/deps.nix {
    inherit lib beamPackages;
  };

  # Disable checks for now
  doCheck = false;

  meta.mainProgram = "sower_client";
}

