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
      ../../apps/sower_agent
      ../../apps/sower_client
      ../../config
      ../../mix.exs
      ../../mix.lock
      ../../VERSION
    ];
  };

  mixReleaseName = "agent";

  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };

  postInstall = ''
    mv $out/bin/agent $out/bin/sower-agent
  '';

  # Disable checks for now
  doCheck = false;

  meta.mainProgram = "sower-agent";
}
