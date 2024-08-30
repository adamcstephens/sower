{
  lib,
  beamPackages,
  elixir,
  esbuild,
  rustPlatform,
  tailwindcss,
  stdenv,
}:
let
  arch = if stdenv.isAarch64 then "arm64" else "x64";
  os = if stdenv.isDarwin then "darwin" else "linux";
in
beamPackages.mixRelease {
  pname = "sower";
  version = builtins.readFile ../VERSION;

  inherit elixir;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../assets
      ../config
      ../lib
      ../mix.exs
      ../priv
      ../rel
      ../test
      ../VERSION
    ];
  };

  mixNixDeps = import ./mix.nix {
    inherit lib beamPackages;
    overrides = _: prev: {
      esbuild = prev.esbuild.override (old: {
        patches = [ ./esbuild-loadpaths.patch ];
      });
      mime = prev.mime.override {
        # mime config needs to be added at compile time
        appConfigPath = ../config;
      };
      tailwind = prev.tailwind.override (old: {
        patches = [ ./tailwind-loadpaths.patch ];
      });
      uuidv7 = prev.uuidv7.override (
        old:
        let
          native = rustPlatform.buildRustPackage {
            pname = "uuidv7";
            version = old.version;
            src = "${old.src}/native/uuidv7";
            cargoSha256 = "sha256-wSbI7J2vNjqjT4zDMbN7pO2D7KI1Vzh0j3chM8AKN9E=";
          };
        in
        {
          appConfigPath = ../config;

          preConfigure = ''
            mkdir -p priv/native
            cp ${native}/lib/libuuidv7.so priv/native/
          '';

          env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
          env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "fake";
        }
      );
    };
  };

  postBuild = ''
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-${os}-${arch}
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-${os}-${arch}

    mix assets.deploy --no-deps-check
  '';
}
