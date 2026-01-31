{
  lib,
  sowerLib,
  pkgs,
  callPackages,
  beamPackages,
  esbuild,
  tailwindcss,
  stdenv,
  version,
  sowerServicesHook,
}:
let
  arch = if stdenv.isAarch64 then "arm64" else "x64";
  os = if stdenv.isDarwin then "darwin" else "linux";
in
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

  nativeBuildInputs = [ sowerServicesHook ];

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
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-${os}-${arch}
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-${os}-${arch}

    mix do deps.loadpaths --no-deps-check + assets.deploy --no-deps-check
  '';

  postInstall = ''
    mv $out/bin/server $out/bin/sower-server
  '';

  # disabled because requires test deps to work
  # doCheck = true;
  # nativeCheckInputs = [
  #   postgresql
  #   postgresqlTestHook
  # ];
  # checkPhase = ''
  #   runHook preCheck
  #
  #   export MIX_ENV=test
  #
  #   ${nixpkgs}/pkgs/development/beam-modules/mix-configure-hook.sh
  #
  #   mix do deps.loadpaths --no-deps-check + test
  #
  #   runHook postCheck
  # '';

  passthru = {
    inherit mixNixDeps;
  };

  meta.mainProgram = "sower-server";
}
