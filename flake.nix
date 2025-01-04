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
          ./nix/flake-module.nix
          ./nix/legacy-flake-module.nix
          inputs.process-compose-flake.flakeModule
        ];

        systems = [
          "x86_64-linux"
          "aarch64-linux"
          # "aarch64-darwin"
        ];

        perSystem =
          {
            config,
            lib,
            pkgs,
            self',
            ...
          }:
          let
            version = builtins.readFile ./VERSION;

            beamPackages = pkgs.beam_minimal.packages.erlang_27;
            elixir = beamPackages.elixir_1_18;

            arch = if pkgs.stdenv.isAarch64 then "arm64" else "x64";
            os = if pkgs.stdenv.isDarwin then "darwin" else "linux";
          in
          {
            devShells.default = pkgs.mkShell {
              inputsFrom = [ config.process-compose.devServices.services.outputs.devShell ];

              packages =
                [
                  # elixir
                  beamPackages.erlang
                  elixir
                  (beamPackages.elixir-ls.override { inherit elixir; })
                  pkgs.next-ls

                  # go
                  pkgs.go_1_23
                  pkgs.delve
                  pkgs.gci
                  pkgs.golangci-lint
                  pkgs.gopls
                  pkgs.oapi-codegen

                  # rust
                  pkgs.cargo

                  pkgs.attic-client
                  self'.packages.seed-ci

                  pkgs.docker
                  pkgs.just
                  pkgs.mix2nix
                  pkgs.nix-eval-jobs
                  pkgs.nvfetcher
                  pkgs.process-compose
                  config.process-compose.devServices.outputs.package
                  pkgs.watchexec
                ]
                ++ lib.optionals pkgs.stdenv.isLinux [
                  # elixir
                  pkgs.inotify-tools
                ];

              shellHook = ''
                export PC_CONFIG_FILES=${config.process-compose.devServices.outputs.settingsFile}

                mkdir -vp _build

                if [ ! -h _build/tailwind-${os}-${arch} ]; then
                  rm -f _build/tailwind-${os}-${arch}
                  ln -sf ${lib.getExe pkgs.tailwindcss} _build/tailwind-${os}-${arch}
                fi

                if [ ! -h _build/esbuild-${os}-${arch} ]; then
                  rm -f _build/esbuild-${os}-${arch}
                  ln -sf ${lib.getExe pkgs.esbuild} _build/esbuild-${os}-${arch}
                fi
              '';

              # go delve fix
              hardeningDisable = [ "fortify" ];
            };

            checks = lib.optionalAttrs pkgs.stdenv.isLinux {
              default = pkgs.callPackage ./nix/tests/e2e.nix {
                flake = self;
              };
            };

            packages = {
              seed-ci = pkgs.callPackage ./nix/packages/seed-ci.nix { };
              client = pkgs.callPackage ./nix/packages/client.nix {
                buildGoModule = pkgs.buildGo123Module;
                inherit version;
              };
              server = pkgs.callPackage ./nix/packages/server.nix { inherit beamPackages elixir version; };
            };

            process-compose.devServices =
              { config, ... }:
              {
                imports = [
                  inputs.services-flake.processComposeModules.default
                  (inputs.services-flake.lib.multiService ./nix/dev-services/epmd.nix)
                ];

                services.epmd.epmd1 = {
                  enable = true;
                  package = beamPackages.erlang;
                };

                services.postgres.postgres1 = {
                  enable = true;
                  superuser = "postgres";
                };

                services.grafana.grafana1 = {
                  enable = true;
                  datasources = [
                    {
                      name = "Tempo";
                      type = "tempo";
                      access = "proxy";
                      url = "http://${config.services.tempo.tempo1.httpAddress}:${builtins.toString config.services.tempo.tempo1.httpPort}";
                    }
                  ];

                  # https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana
                  extraConf = {
                    "auth.anonymous" = {
                      enabled = true;
                      org_role = "Admin";
                      hide_version = false;
                    };

                    "auth.basic".enabled = false;
                    "auth".disable_login_form = true;
                  };
                };
                services.tempo.tempo1.enable = true;
              };
          };

        flake = {
          nixosModules.sower = ./nix/nixos/module.nix;
          homeModules.sower = ./nix/home/module.nix;
        };
      }
    );
}
