{
  inputs = {
    attic.url = "github:zhaofengli/attic";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable-small";
    next-ls.url = "github:elixir-tools/next-ls";
    next-ls.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ./nix/flakemodule.nix ];

      systems = [
        # requires support in package.nix for tailwind/esbuild
        "x86_64-linux"
        "aarch64-linux"
      ];

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

              inputs'.attic.packages.attic

              pkgs.docker
              pkgs.just
              pkgs.mix2nix
              pkgs.nvfetcher
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
            seed-ci = pkgs.callPackage ./nix/seed-ci.nix { inherit (inputs'.attic.packages) attic; };
            seed-ci-docker = pkgs.callPackage ./nix/docker-image.nix { inherit seed-ci; };
          };
        };
      flake.packages.aarch64-darwin.seed-ci =
        inputs.nixpkgs.legacyPackages.aarch64-darwin.callPackage ./nix/seed-ci.nix
          { inherit (inputs.attic.packages.aarch64-darwin) attic; };

      flake.nixosModules.sower = ./nix/module.nix;
    };
}
