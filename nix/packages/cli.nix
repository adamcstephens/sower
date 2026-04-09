{
  activator,
  beamPackages,
  callPackages,
  lib,
  makeWrapper,
  version,
}:

beamPackages.mixRelease {
  pname = "sower-cli";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../apps/nix
      ../../apps/sower_cli
      ../../apps/sower_client
      ../../config
      ../../mix.exs
      ../../mix.lock
      ../../VERSION
    ];
  };

  mixReleaseName = "cli";

  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };

  removeCookie = false;

  nativeBuildInputs = [
    makeWrapper
  ];

  postInstall = ''
    mv $out/bin/cli $out/bin/sower
    wrapProgram $out/bin/sower --add-flags "eval 'SowerCli.main(System.argv())'" --suffix PATH : ${lib.makeBinPath [ activator ]}
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    export MIX_ENV=test
    ln -sv $PWD/_build/prod _build/test

    pushd apps/sower_cli
    mix do deps.loadpaths --no-deps-check + test
    popd

    export MIX_ENV=prod

    runHook postCheck
  '';

  meta.mainProgram = "sower";
}
