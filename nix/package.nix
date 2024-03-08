{
  lib,
  beamPackages,
  esbuild,
  tailwindcss,
  fmt,
  git,
  libgit2,
  sqlite,
  stdenv,
}:
let
  arch = if stdenv.isAarch64 then "arm64" else "x64";
  os = if stdenv.isDarwin then "darwin" else "linux";
in
beamPackages.mixRelease {
  pname = "sower";
  version = "0.0.1-dev";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (
      file: file.name != "bin" && file.name != "nix" && !file.hasExt "nix"
    ) ../.;
  };

  elixir = beamPackages.elixir_1_16;

  mixNixDeps = import ./mix.nix {
    inherit lib beamPackages;
    overrides = _: prev: {
      egit = prev.egit.override (old: {
        nativeBuildInputs = [
          fmt
          git
          libgit2
        ];
        patches = [ ./egit-skip-submodule.patch ];
      });
      esbuild = prev.esbuild.override (old: {
        patches = [ ./esbuild-loadpaths.patch ];
      });
      exqlite = prev.exqlite.override (old: {
        env = (old.env or { }) // {
          EXQLITE_USE_SYSTEM = "1";
          EXQLITE_SYSTEM_CFLAGS = "-I${sqlite.dev}/include";
          EXQLITE_SYSTEM_LDFLAGS = "-L${sqlite.out}/lib -lsqlite3";
        };
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
}
