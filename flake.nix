{
  inputs = {
    attic.url = "github:zhaofengli/attic";
    crane.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    flake-parts.url = "github:hercules-ci/flake-parts";
    lexical.inputs.nixpkgs.follows = "nixpkgs";
    lexical.url = "github:lexical-lsp/lexical";
    next-ls.url = "github:elixir-tools/next-ls";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable-small";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { withSystem, ... }:
      {
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
            beamPackages = pkgs.beam.packagesWith pkgs.erlang;
            elixir = beamPackages.elixir_1_16;
            lexical = inputs'.lexical.packages.default.override { inherit elixir; };
            next-ls = inputs'.next-ls.packages.default.override { };

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
              packages =
                [
                  elixir
                  beamPackages.elixir-ls
                  next-ls

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
                ]
                ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]
                ++ lib.optionals pkgs.stdenv.isDarwin [
                  pkgs.libiconv
                  pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
                ];

              nativeBuildInputs = [
                pkgs.fmt
                pkgs.libgit2
              ];

              shellHook = ''
                export LEXICAL_START_PATH="${lexical}/binsh/start_lexical.sh"
              '';
            };

            legacyPackages = {
              inherit beamPackages;
            };
            packages = rec {

              seed-ci = pkgs.callPackage ./nix/seed-ci.nix { inherit (inputs'.attic.packages) attic; };

              # legacy alias
              cli = client;

              client = craneLib.buildPackage (
                craneLib.crateNameFromCargoToml { cargoToml = ./client/Cargo.toml; }
                // {
                  src =
                    with lib.fileset;
                    toSource {
                      root = ./.;
                      fileset = unions [
                        ./client
                        ./Cargo.lock
                        ./Cargo.toml
                      ];
                    };
                  strictDeps = true;

                  CARGO_BUILD_TARGET = rustTarget;
                  CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";

                  buildInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin [
                    pkgs.libiconv
                    pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
                  ];

                  meta.mainProgram = "sower";
                }
              );
            };
          };

        flake.nixosModules.sower = ./nix/nixos-module.nix;
        flake.homeModules.sower = ./nix/home-module.nix;

        # don't support darwin
        flake.packages.x86_64-linux = rec {
          default = server;
          server = withSystem "x86_64-linux" (
            { pkgs, self', ... }:
            pkgs.callPackage ./nix/package.nix { inherit (self'.legacyPackages) beamPackages; }
          );
        };
      }
    );
}
