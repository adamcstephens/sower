{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-filter.url = "github:numtide/nix-filter";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [];

      systems = ["x86_64-linux"]; # needs support in package as well

      perSystem = {
        inputs',
        lib,
        pkgs,
        self',
        ...
      }: {
        devShells.default = pkgs.mkShell {
          packages =
            [
              pkgs.beam.packages.erlangR25.elixir_1_15
              pkgs.beam.packages.erlangR25.elixir-ls

              pkgs.cargo
              pkgs.openssl.dev
              pkgs.pkg-config
              pkgs.rustc
              pkgs.rust-analyzer
              pkgs.rustfmt

              pkgs.beekeeper-studio
              pkgs.just
              pkgs.mix2nix
              pkgs.process-compose
            ]
            ++ (lib.optionals pkgs.stdenv.isLinux [pkgs.inotify-tools]);
        };

        packages = rec {
          default = sower;

          sower = pkgs.callPackage ./nix/package.nix {
            nix-filter = inputs.nix-filter.lib;
          };
        };
      };
    };
}
