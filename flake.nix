{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable-small";
    next-ls.url = "github:elixir-tools/next-ls";
    next-ls.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ./nix/part.nix ];

      systems = [ "x86_64-linux" ]; # needs support in package as well

      perSystem =
        {
          inputs',
          lib,
          pkgs,
          self',
          ...
        }:
        let
          erlang = pkgs.beam.interpreters.erlangR26;
          beam = pkgs.beam.packagesWith erlang;
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [
              beam.elixir_1_16
              beam.elixir-ls
              (inputs'.next-ls.packages.default.override {
                beamPackages = beam;
                elixir = beam.elixir_1_16;
              })

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
              pkgs.sqlite
            ] ++ (lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]);

            nativeBuildInputs = [
              pkgs.fmt
              pkgs.libgit2
            ];
          };

          packages = rec {
            default = pkgs.callPackage ./nix/package.nix { beamPackages = beam; };
          };
        };
    };
}
