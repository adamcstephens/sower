{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    expert.url = "github:elixir-lang/expert?ref=main";
    expert.inputs.nixpkgs.follows = "nixpkgs";
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
            inputs',
            lib,
            pkgs,
            self',
            ...
          }:
          let
            version = builtins.readFile ./VERSION;

            beamPackages = pkgs.beamMinimal28Packages.extend (
              _: prev: {
                elixir = prev.elixir_1_19;
              }
            );

            arch = if pkgs.stdenv.isAarch64 then "arm64" else "x64";
            os = if pkgs.stdenv.isDarwin then "darwin" else "linux";
          in
          {
            _module.args = {
              inherit beamPackages version;
            };

            devShells = {
              ci = pkgs.mkShell {
                packages = [
                  pkgs.attic-client
                  self'.packages.cli
                ];
              };

              default = pkgs.mkShell {
                packages = [
                  # elixir
                  beamPackages.erlang
                  beamPackages.elixir
                  beamPackages.hex
                  inputs'.expert.packages.expert

                  # elixir deps build deps
                  pkgs.cargo

                  # go
                  pkgs.go
                  pkgs.delve
                  # broken 2025-09-19 pkgs.gci
                  pkgs.golangci-lint
                  pkgs.gopls
                  pkgs.oapi-codegen

                  pkgs.attic-client
                  pkgs.nushell

                  pkgs.just
                  pkgs.mix2nix
                  pkgs.nix-eval-jobs
                  pkgs.nvfetcher
                  pkgs.process-compose
                  pkgs.postgresql
                  pkgs.sd-switch
                  pkgs.entr

                  self'.packages.activator
                ]
                ++ lib.optionals pkgs.stdenv.isLinux [
                  # elixir
                  pkgs.inotify-tools
                ];

                shellHook = ''
                  mkdir -vp _build

                  ln -sf ${lib.getExe pkgs.tailwindcss_3} _build/tailwind-${os}-${arch}
                  ln -sf ${lib.getExe pkgs.esbuild} _build/esbuild-${os}-${arch}
                '';

                # go delve fix
                hardeningDisable = [ "fortify" ];
              };
            };
          };
      }
    );
}
