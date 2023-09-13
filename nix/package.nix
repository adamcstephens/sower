{
  lib,
  beamPackages,
  nix-filter,
  esbuild,
  tailwindcss,
}:
beamPackages.mixRelease rec {
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
  };

  # mixFodDeps = beamPackages.fetchMixDeps {
  #   pname = "mix-deps-${pname}";
  #   inherit src version;
  #   hash = "sha256-PmFAyEA8JigeTgApVrjvc8Ig+aTNGEgpIMFVFX3GEOc=";
  # };

  postBuild = ''
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-linux-x64
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-linux-x64

    mix assets.deploy --no-deps-check
  '';
}
