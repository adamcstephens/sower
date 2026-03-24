{
  beamPackages,
  callPackages,
  lib,
  version,
}:

beamPackages.mixRelease {
  pname = "sower-garden";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../apps/nix
      ../../apps/garden
      ../../apps/sower_client
      ../../config
      ../../mix.exs
      ../../mix.lock
      ../../libs/rexec
      ../../VERSION
    ];
  };

  mixReleaseName = "garden";

  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };

  postInstall = ''
    mv $out/bin/garden $out/bin/sower-garden
  '';

  # Disable checks for now
  doCheck = false;

  meta.mainProgram = "sower-garden";
}
