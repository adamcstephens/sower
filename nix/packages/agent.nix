{
  beamPackages,
  callPackages,
  lib,
  version,
}:

beamPackages.mixRelease {
  pname = "sower-agent";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../agent
      ../../client-elixir
    ];
  };

  preConfigure = ''
    cd agent
  '';

  mixNixDeps = callPackages ../../agent/deps.nix {
    inherit lib beamPackages;
  };

  postInstall = ''
    mv $out/bin/sower_agent $out/bin/sower-agent
  '';

  # Disable checks for now
  doCheck = false;

  meta.mainProgram = "sower-agent";
}
