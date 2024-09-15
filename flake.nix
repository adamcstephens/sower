{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
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
            lib,
            pkgs,
            self',
            ...
          }:
          let
            beamPackages = pkgs.beam_minimal.packages.erlang_27;
            elixir = beamPackages.elixir_1_17;
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
                  pkgs.go_1_23
                  pkgs.delve
                  pkgs.gopls
                  pkgs.oapi-codegen

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
                ];

              # go delve fix
              hardeningDisable = [ "fortify" ];
            };

            checks = lib.optionalAttrs pkgs.stdenv.isLinux {
              default = pkgs.callPackage ./nix/test-end-to-end.nix { flake = self; };
            };

            packages = {
              seed-ci = pkgs.callPackage ./nix/seed-ci.nix { };
              client = pkgs.callPackage ./nix/client-package.nix { buildGoModule = pkgs.buildGo123Module; };
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
