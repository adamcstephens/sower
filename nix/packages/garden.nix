{
  beamPackages,
  callPackages,
  getent,
  lib,
  version,
  tzdata,
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
      ../../VERSION
    ];
  };

  nativeBuildInputs = [ tzdata ];

  mixReleaseName = "garden";

  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };

  postInstall = ''
    mv $out/bin/garden $out/bin/sower-garden
  '';

  doCheck = true;
  nativeCheckInputs = [
    getent
  ];
  checkPhase = ''
    runHook preCheck

    export MIX_ENV=test
    ln -sv $PWD/_build/prod _build/test

    pushd apps/garden
    mix do deps.loadpaths --no-deps-check + test
    popd

    export MIX_ENV=prod

    runHook postCheck
  '';

  meta.mainProgram = "sower-garden";
}
