{
  inputs = {
    attic.url = "github:zhaofengli/attic";
    lexical.url = "github:lexical-lsp/lexical";
    lexical.inputs.nixpkgs.follows = "nixpkgs";
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
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
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
          beam = pkgs.beam.packagesWith pkgs.erlang;
          lexical = inputs'.lexical.packages.default.override { elixir = beam.elixir_1_16; };
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [
              beam.elixir_1_16
              beam.elixir-ls

              inputs'.attic.packages.attic
              self'.packages.seed-ci

              pkgs.docker
              pkgs.just
              pkgs.mix2nix
              pkgs.nvfetcher
              pkgs.process-compose
              pkgs.sqlite

              pkgs.delve
              pkgs.go
              pkgs.golangci-lint
              pkgs.gopls
              pkgs.go-tools
              pkgs.gotools
            ] ++ (lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]);

            nativeBuildInputs = [
              pkgs.fmt
              pkgs.libgit2
            ];

            shellHook = ''
              export LEXICAL_START_PATH="${lexical}/binsh/start_lexical.sh"
            '';
          };

          packages = rec {
            default = pkgs.callPackage ./nix/package.nix { beamPackages = beam; };
            seed-ci = pkgs.callPackage ./nix/seed-ci.nix { inherit (inputs'.attic.packages) attic; };
            sower-tree = pkgs.callPackage ./nix/sower-tree.nix { };
          };
        };

      flake.nixosModules.sower = ./nix/module.nix;
    };
}
