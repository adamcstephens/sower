{
  lib,
  beamPackages,
  elixir,
  esbuild,
  rustPlatform,
  tailwindcss,
  stdenv,
  version,
}:
let
  arch = if stdenv.isAarch64 then "arm64" else "x64";
  os = if stdenv.isDarwin then "darwin" else "linux";
in
beamPackages.mixRelease rec {
  pname = "sower";
  inherit version;

  inherit elixir;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../assets
      ../../config
      ../../lib
      ../../mix.exs
      ../../mix.lock
      ../../priv
      ../../test
      ../../VERSION
    ];
  };

  mixNixDeps = import ./mix.nix {
    inherit lib beamPackages;
    overrides = _: prev: {
      argon2 = prev.argon2.override (
        old:
        let
          native = rustPlatform.buildRustPackage {
            pname = "argon2";
            version = old.version;
            src = "${old.src}/native";
            cargoHash = "sha256-vlWLcEvqQVvc4ksdSYLzjrL7nJxux+Kz4LrrhK/ph9c=";
          };
        in
        {
          # pre-build the make target
          preBuild = ''
            mkdir -p priv/
            cp ${native}/lib/libargon2.so priv/argon2_${old.version}.so
          '';

          # move native into expected location
          postInstall = ''
            mv $out/lib/erlang/lib/argon2-${old.version}/priv/argon2_${old.version}.so $out/lib/erlang/lib/argon2-${old.version}/priv/argon2.so
          '';
        }
      );

      esbuild = prev.esbuild.override (old: {
        patches = [ ./esbuild-loadpaths.patch ];
      });

      tailwind = prev.tailwind.override (old: {
        patches = [ ./tailwind-loadpaths.patch ];
      });
    };
  };

  postBuild = ''
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-${os}-${arch}
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-${os}-${arch}

    mix assets.deploy --no-deps-check
  '';

  # disabled because requires a db to work
  # doCheck = false;
  # checkPhase = ''
  #   runHook preCheck
  #
  #   export MIX_ENV=test
  #
  #   ${nixpkgs}/pkgs/development/beam-modules/mix-configure-hook.sh
  #
  #   mix do deps.loadpaths --no-deps-check, test
  #
  #   runHook postCheck
  # '';

  passthru = {
    inherit mixNixDeps;
  };

  meta.mainProgram = "sower";
}
