{
  lib,
  beamPackages,
  callPackages,
  coreutils,
  util-linux,
}:
beamPackages.mixRelease {
  pname = "cloud-hypervisor-library";
  version = "0.1.6";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../apps/cloud_hypervisor
      ../../mix.lock
    ];
  };

  sourceRoot = "source/apps/cloud_hypervisor";
  mixEnv = "test";
  mixReleaseName = "cloud_hypervisor";
  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };
  env.MIX_BUILD_PATH = "_build/test";
  env.MIX_DEPS_PATH = "deps";

  nativeCheckInputs = [ util-linux ];
  postPatch = ''
    substituteInPlace test/process_test.exs \
      --replace-fail '/usr/bin/env' '${coreutils}/bin/env'
  '';
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    mix do deps.loadpaths --no-deps-check + compile --warnings-as-errors + test --no-deps-check
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir --parents $out
    cp --recursive _build/test/lib/cloud_hypervisor/ebin $out/
    runHook postInstall
  '';
}
