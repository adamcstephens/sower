{
  bashNonInteractive,
  beamPackages,
  callPackages,
  cli,
  e2fsprogs,
  getent,
  lib,
  nix,
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
      ../../apps/vm_manager
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
    substituteInPlace \
      apps/vm_manager/test/vm_manager/regression_test.exs \
      apps/vm_manager/test/vm_manager/restart_policy_test.exs \
      apps/vm_manager/test/runtime_resources_test.exs \
      apps/vm_manager/test/vm_manager/manager_intent_test.exs \
      apps/garden/test/garden/vm_cli_test.exs \
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
    cli
    (lib.getBin nix)
    e2fsprogs
    getent
  ];
  checkPhase = ''
    runHook preCheck

    export MIX_ENV=test
    export NIX_REMOTE=local
    export NIX_STATE_DIR="$TMPDIR/nix-state"
    export NIX_LOG_DIR="$TMPDIR/nix-log"
    export NIX_CONF_DIR="$TMPDIR/nix-conf"
    export NIX_CONFIG='build-users-group ='
    mkdir --parents "$NIX_CONF_DIR"
    ln -sv $PWD/_build/prod _build/test

    for app in vm_manager garden; do
      pushd "apps/$app"
      mix do deps.loadpaths --no-deps-check + test
      popd
    done

    export MIX_ENV=prod

    runHook postCheck
  '';

  meta.mainProgram = "sower-garden";
}
