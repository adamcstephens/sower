{
  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    flake-parts.url = "github:hercules-ci/flake-parts";
    crane.url = "github:ipetkov/crane";

    circus.url = "github:manic-systems/circus?ref=main";
    circus.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { ... }:
      {
        imports = [
          ./nix/flake/part.nix
          ./nix/packages/part.nix
          ./nix/tests/part.nix
        ];

        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];

        perSystem =
          {
            lib,
            pkgs,
            self',
            ...
          }:
          let
            version = builtins.readFile ./VERSION;

            beamPackages = pkgs.beamMinimal29Packages.overrideScope (
              _: prev: {
                elixir = prev.elixir_1_20;
              }
            );

            craneLib = inputs.crane.mkLib pkgs;
            circusPackages = inputs.circus.packages.${pkgs.stdenv.hostPlatform.system};
            circusQueueRunner =
              circusPackages.circus-queue-runner.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [
                  ./nix/packages/circus-products.patch
                  ./nix/packages/circus-agent-products.patch
                ];
              });
            circusAgent =
              circusPackages.circus-agent.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [
                  ./nix/packages/circus-products.patch
                  ./nix/packages/circus-agent-products.patch
                ];
              });
            circusServer =
              circusPackages.circus-server.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [ ./nix/packages/circus-cache-products.patch ];
              });
          in
          {
            _module.args = {
              inherit beamPackages craneLib version;
            };

            devShells = {
              ci = pkgs.mkShell {
                packages = [
                  pkgs.niks3
                  self'.packages.sower
                ];
              };

              default = pkgs.mkShell {
                packages = [
                  inputs.circus.packages.${pkgs.stdenv.hostPlatform.system}.circus-cli
                  circusAgent
                  circusServer
                  inputs.circus.packages.${pkgs.stdenv.hostPlatform.system}.circus-evaluator
                  circusQueueRunner
                  # elixir
                  beamPackages.erlang
                  beamPackages.elixir
                  beamPackages.hex

                  # rust
                  pkgs.cargo
                  pkgs.cargo-edit
                  pkgs.clippy
                  pkgs.rustc
                  pkgs.rust-analyzer
                  pkgs.rustfmt

                  pkgs.attic-client
                  pkgs.niks3
                  pkgs.nushell

                  # dev tools
                  pkgs.curl
                  pkgs.entr
                  pkgs.just
                  pkgs.npins
                  pkgs.nvfetcher
                  pkgs.postgresql_17
                  pkgs.process-compose
                  pkgs.s5cmd
                  pkgs.seaweedfs
                  pkgs.sd-switch
                ]
                ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                  # elixir
                  pkgs.inotify-tools
                ];

                env = {
                  # prevent mix from trying to download binaries
                  TAILWIND_PATH = lib.getExe pkgs.tailwindcss_3;
                  ESBUILD_PATH = lib.getExe pkgs.esbuild;
                };
              };
            };
          };

        sower.devshells.enable = true;
      }
    );
}
