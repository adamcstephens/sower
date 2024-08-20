{
  inputs = {
    crane.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
    services-flake.url = "github:juspay/services-flake";
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { ... }:
      {
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
            beamPackages = pkgs.beam_minimal.packages.erlang_27;
            elixir = beamPackages.elixir_1_17;

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
                  (beamPackages.elixir-ls.override { inherit elixir; })
                  pkgs.next-ls

                  # go
                  pkgs.go_1_22
                  pkgs.delve
                  pkgs.gopls

                  # rust
                  pkgs.cargo
                  pkgs.cargo-outdated
                  pkgs.cargo-watch
                  pkgs.clippy
                  pkgs.lldb
                  pkgs.llvm
                  pkgs.rust-analyzer
                  pkgs.rustc
                  pkgs.rustfmt

                  pkgs.attic-client
                  self'.packages.seed-ci

                  pkgs.docker
                  pkgs.just
                  pkgs.mix2nix
                  pkgs.nvfetcher
                  pkgs.process-compose
                  pkgs.postgresql
                  pkgs.watchexec
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

              # og delve fix
              hardeningDisable = [ "fortify" ];

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
              default = pkgs.callPackage ./nix/test-end-to-end.nix { flake = self; };
            };

            packages = {
              seed-ci = pkgs.callPackage ./nix/seed-ci.nix { };
              client = pkgs.callPackage ./nix/client-rust-package.nix { inherit craneLib rustTarget; };
              client-go = pkgs.callPackage ./nix/client-go-package.nix { buildGoModule = pkgs.buildGo122Module; };
              server = pkgs.callPackage ./nix/server-package.nix { inherit beamPackages elixir; };
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
        };
      }
    );
}
