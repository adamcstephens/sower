{
  inputs = {
    attic.url = "github:zhaofengli/attic";
    crane.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    flake-parts.url = "github:hercules-ci/flake-parts";
    lexical.inputs.nixpkgs.follows = "nixpkgs";
    lexical.url = "github:lexical-lsp/lexical";
    next-ls.inputs.nixpkgs.follows = "nixpkgs";
    next-ls.url = "github:elixir-tools/next-ls";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable-small";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
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

          rustTarget =
            if pkgs.stdenv.isLinux then
              "${pkgs.hostPlatform.qemuArch}-unknown-linux-musl"
            else
              "${pkgs.hostPlatform.qemuArch}-apple-darwin";

          rustToolchain = inputs'.rust-overlay.packages.rust.override { targets = [ rustTarget ]; };

          craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;
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

              pkgs.cargo
              pkgs.rustc
              pkgs.clippy
              pkgs.rust-analyzer
              pkgs.rustfmt
            ] ++ (lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]);

            nativeBuildInputs = [
              pkgs.fmt
              pkgs.libgit2
            ];

            shellHook = ''
              export LEXICAL_START_PATH="${lexical}/binsh/start_lexical.sh"
            '';
          };

          packages = {
            default = pkgs.callPackage ./nix/package.nix { beamPackages = beam; };
            seed-ci = pkgs.callPackage ./nix/seed-ci.nix { inherit (inputs'.attic.packages) attic; };
            sower-tree = pkgs.callPackage ./nix/sower-tree.nix { };

            cli = craneLib.buildPackage {
              src = craneLib.cleanCargoSource (craneLib.path ./cli);
              strictDeps = true;

              CARGO_BUILD_TARGET = rustTarget;
              CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";

              buildInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin [
                pkgs.libiconv
                pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
              ];
            };
          };
        };

      flake.nixosModules.sower = ./nix/module.nix;
    };
}
