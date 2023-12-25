{
  lib,
  beamPackages,
  nix-filter,
  esbuild,
  tailwindcss,
  fmt,
  git,
  libgit2,
}:
beamPackages.mixRelease {
  pname = "sower";
  version = "0.0.1-dev";

  src = nix-filter {
    root = ../.;
    include = [
      "assets"
      "config"
      "lib"
      "mix.exs"
      "mix.lock"
      "priv"
      "test"
    ];
  };

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
    };
  };

  postBuild = ''
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-linux-x64
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-linux-x64

    mix assets.deploy --no-deps-check
  '';
}
