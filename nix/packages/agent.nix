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
    root = ../../agent;
    fileset = lib.fileset.unions [
      ../../agent
    ];
  };

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
