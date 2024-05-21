{
  inputs = {
    attic.url = "github:zhaofengli/attic";
    crane.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    flake-parts.url = "github:hercules-ci/flake-parts";
    next-ls.url = "github:elixir-tools/next-ls";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
    services-flake.url = "github:juspay/services-flake";
    typhon.inputs.nixpkgs.follows = "nixpkgs";
    typhon.url = "github:typhon-ci/typhon";
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { lib, withSystem, ... }:
      rec {
        imports = [
          ./nix/flakemodule.nix
          inputs.process-compose-flake.flakeModule
        ];

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
            beamPackages = pkgs.beam.packagesWith pkgs.erlangR26;
            elixir = beamPackages.elixir_1_16;
            lexical = pkgs.lexical.override { inherit elixir; };
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
                  # elixir
                  elixir
                  beamPackages.elixir-ls
                  lexical
                  next-ls

                  # rust
                  pkgs.cargo
                  pkgs.clippy
                  pkgs.rust-analyzer
                  pkgs.rustc
                  pkgs.rustfmt

                  inputs'.attic.packages.attic
                  self'.packages.seed-ci

                  pkgs.docker
                  pkgs.just
                  pkgs.mix2nix
                  pkgs.nvfetcher
                  pkgs.process-compose
                  pkgs.postgresql
                ]
                ++ lib.optionals pkgs.stdenv.isLinux [
                  # elixir
                  pkgs.inotify-tools

                  # rust
                  pkgs.gdb
                ]
                ++ lib.optionals pkgs.stdenv.isDarwin [
                  pkgs.libiconv
                  pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
                ];

              shellHook = ''
                export BINDGEN_EXTRA_CLANG_ARGS="$(< ${pkgs.stdenv.cc}/nix-support/libc-crt1-cflags) \
                      $(< ${pkgs.stdenv.cc}/nix-support/libc-cflags) \
                      $(< ${pkgs.stdenv.cc}/nix-support/cc-cflags) \
                      $(< ${pkgs.stdenv.cc}/nix-support/libcxx-cxxflags) \
                      ${lib.optionalString pkgs.stdenv.cc.isClang "-idirafter ${pkgs.stdenv.cc.cc}/lib/clang/${lib.getVersion pkgs.stdenv.cc.cc}/include"} \
                      ${lib.optionalString pkgs.stdenv.cc.isGNU "-isystem ${pkgs.stdenv.cc.cc}/include/c++/${lib.getVersion pkgs.stdenv.cc.cc} -isystem ${pkgs.stdenv.cc.cc}/include/c++/${lib.getVersion pkgs.stdenv.cc.cc}/${pkgs.stdenv.hostPlatform.config} -idirafter ${pkgs.stdenv.cc.cc}/lib/gcc/${pkgs.stdenv.hostPlatform.config}/${lib.getVersion pkgs.stdenv.cc.cc}/include"} \
                    "
              '';
            };

            checks = lib.optionalAttrs pkgs.stdenv.isLinux {
              default = pkgs.callPackage ./nix/test-end-to-end.nix { client = self'.packages.client; };
            };

            packages = {
              seed-ci = pkgs.callPackage ./nix/seed-ci.nix { inherit (inputs'.attic.packages) attic; };
              client = pkgs.callPackage ./nix/client-package.nix { inherit craneLib rustTarget; };
              server = pkgs.callPackage ./nix/server-package.nix { };
            };

            process-compose."default" = {
              imports = [ inputs.services-flake.processComposeModules.default ];

              services.postgres."pg1" = {
                enable = true;
                superuser = "postgres";
              };
            };
          };

        flake = {
          nixosModules.sower = ./nix/nixos-module.nix;
          homeModules.sower = ./nix/home-module.nix;

          typhonProject = inputs.typhon.lib.gitea.mkProject {
            instance = "git.junco.dev";
            owner = "adam";
            repo = "sower";
            secrets = ./nix/typhon-secrets.age;
            typhonUrl = "https://typhon.junco.dev";
          };
          typhonJobs = lib.recursiveUpdate (inputs.nixpkgs.lib.genAttrs systems (system: {
            inherit (self.packages.${system}) client;
          })) { x86_64-linux.server = self.packages.x86_64-linux.server; };
        };
      }
    );
}
