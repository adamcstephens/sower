{
  lib,

  beamPackages,
  callPackages,
  tzdata,
  version,
}:
beamPackages.mixRelease {
  pname = "sower-mix-checks";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../.formatter.exs
      ../../apps
      ../../config
      ../../mix.exs
      ../../mix.lock
      ../../VERSION
    ];
  };

  # need to set a release name
  mixReleaseName = "server";
  mixEnv = "test";

  nativeBuildInputs = [ tzdata ];

  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };

  dontBuild = true;
  installPhase = ''
    touch $out
  '';
  dontFixup = true;

  doCheck = true;

  checkPhase = ''
    mix do deps.loadpaths --no-deps-check + format --check-formatted
  '';
}
