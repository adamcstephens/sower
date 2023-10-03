{
  lib,
  beamPackages,
  nix-filter,
  esbuild,
  tailwindcss,
  openssl,
  pkg-config,
  rustPlatform,
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
    overrides = _: prev: {
      ex_git = let
        name = "ex_git";
        version = "0.11.0";

        src = beamPackages.fetchHex {
          pkg = "${name}";
          version = "${version}";
          sha256 = "1lri3xvslkz8m2f65jfkfmqf9b5jjr5r5r865hwlll5bm316s4ck";
        };

        exgitRustler = rustPlatform.buildRustPackage {
          pname = "ex_git_rustler";
          inherit version;

          nativeBuildInputs = [
            pkg-config
          ];

          buildInputs = [
            openssl
          ];

          src = "${src}/native/exgit";
          cargoHash = "sha256-H2dNNrrz+fc4h7YwLVkyumHTpb5Z3koZ2RwRY2OU3EY=";
        };
      in
        beamPackages.buildMix {
          inherit name version src;

          beamDeps = [prev.rustler];

          appConfigPath = ../config;

          postBuild = ''
            rm priv/native/libexgit.so
            ln -s ${exgitRustler}/lib/libexgit.so priv/native/libexgit.so
          '';
        };
    };
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
