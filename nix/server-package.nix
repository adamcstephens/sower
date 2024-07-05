{
  lib,
  beamPackages,
  elixir,
  esbuild,
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
    };
  };

  postBuild = ''
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-${os}-${arch}
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-${os}-${arch}

    mix assets.deploy --no-deps-check
  '';
}
