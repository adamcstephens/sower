{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
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
                  pkgs.niks3
                  self'.packages.cli
                ];
              };

              default = pkgs.mkShell {
                packages = [
                  # elixir
                  beamPackages.erlang
                  beamPackages.elixir
                  beamPackages.expert
                  beamPackages.hex

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
                  pkgs.niks3
                  pkgs.nushell

                  # dev tools
                  pkgs.entr
                  pkgs.just
                  pkgs.mix2nix
                  pkgs.npins
                  pkgs.nvfetcher
                  pkgs.postgresql
                  pkgs.process-compose
                  pkgs.s5cmd
                  pkgs.sd-switch
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
