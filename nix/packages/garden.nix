{
  bashNonInteractive,
  beamPackages,
  callPackages,
  e2fsprogs,
  getent,
  lib,
  version,
  tzdata,
  stockImage ? null,
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
      ../../apps/cloud_hypervisor
      ../../config
      ../../mix.exs
      ../../mix.lock
      ../../VERSION
    ];
  };

  env.TZDIR = "${tzdata}/share/zoneinfo";

  # https://github.com/NixOS/nixpkgs/pull/558236
  buildInputs = [ bashNonInteractive ];


  postPatch = ''
    substituteInPlace apps/garden/test/garden/vm_manager_test.exs \
      --replace-fail '#!/usr/bin/env sh' '#!${bashNonInteractive}/bin/sh'
  '';
  mixReleaseName = "garden";

  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };

  postInstall = ''
    mv $out/bin/garden $out/bin/sower-garden
  ''
  + lib.optionalString (stockImage != null) ''
    mkdir --parents "$out/share/sower"
    ln --symbolic ${stockImage} "$out/share/sower/image"
  '';

  doCheck = true;
  nativeCheckInputs = [
    e2fsprogs
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
