{
  lib,
  pkgs,

  beamPackages,
  callPackages,
  esbuild,
  postgresql,
  postgresqlTestHook,
  sowerLib,
  sowerServicesHook,
  tailwindcss,
  tzdata,
  version,
}:
beamPackages.mixRelease rec {
  pname = "sower-server";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../apps/nix
      ../../apps/sower
      ../../apps/sower_client
      ../../config
      ../../mix.exs
      ../../mix.lock
      ../../VERSION
    ];
  };

  mixReleaseName = "server";

  nativeBuildInputs = [
    sowerServicesHook
    tzdata
  ];

  sowerServices = sowerLib.generateUnitFiles {
    inherit pkgs;
    config = {
      services.sower = {
        wantedBy = [
          "multi-user.target"
        ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "PLACEHOLDER_OUT/bin/sower start";
          ExecStop = "PLACEHOLDER_OUT/bin/sower stop";
        };
      };
    };
  };

  mixNixDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };

  postBuild = ''
    mix do deps.loadpaths --no-deps-check + assets.deploy --no-deps-check
  '';

  postInstall = ''
    mv $out/bin/server $out/bin/sower-server
  '';

  doCheck = true;
  env = {
    PGDATABASE = "sower_test";
    # prevent mix from trying to download binaries
    ESBUILD_PATH = lib.getExe esbuild;
    TAILWIND_PATH = lib.getExe tailwindcss;
  };
  nativeCheckInputs = [
    postgresql
    postgresqlTestHook
  ];
  checkPhase = ''
    runHook preCheck

    export MIX_ENV=test
    ln -sv $PWD/_build/prod _build/test

    pushd apps/sower
    mix do deps.loadpaths --no-deps-check + ecto.setup + test
    popd

    export MIX_ENV=prod

    runHook postCheck
  '';

  passthru = {
    inherit mixNixDeps;
  };

  meta.mainProgram = "sower-server";
}
