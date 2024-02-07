{
  lib,
  beamPackages,
  esbuild,
  tailwindcss,
  fmt,
  git,
  libgit2,
  sqlite,
}:
beamPackages.mixRelease {
  pname = "sower";
  version = "0.0.1-dev";

  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.union ./.. (lib.fileset.fileFilter (file: !file.hasExt "nix") ./..);
  };

  elixir = beamPackages.elixir_1_16;

  mixNixDeps = import ./mix.nix {
    inherit lib beamPackages;
    overrides = _: prev: {
      egit = prev.egit.override (
        old: {
          nativeBuildInputs = [
            fmt
            git
            libgit2
          ];
          patches = [ ./egit-skip-submodule.patch ];
        }
      );
      esbuild = prev.esbuild.override (old: { patches = [ ./esbuild-loadpaths.patch ]; });
      exqlite = prev.exqlite.override (
        old: {
          env = (old.env or { }) // {
            EXQLITE_USE_SYSTEM = "1";
            EXQLITE_SYSTEM_CFLAGS = "-I${sqlite.dev}/include";
            EXQLITE_SYSTEM_LDFLAGS = "-L${sqlite.out}/lib -lsqlite3";
          };
        }
      );
      tailwind = prev.tailwind.override (old: { patches = [ ./tailwind-loadpaths.patch ]; });
    };
  };

  postBuild = ''
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-linux-x64
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-linux-x64

    mix assets.deploy --no-deps-check
  '';
}
