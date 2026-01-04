{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    services-flake.url = "github:juspay/services-flake";

    expert.url = "github:elixir-lang/expert?ref=main";
    expert.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { ... }:
      {
        imports = [
          ./nix/flake/part.nix
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
            devShells = {
              ci = pkgs.mkShell {
                packages = [
                  pkgs.attic-client
                  self'.packages.cli
                ];
              };

              default = pkgs.mkShell {
                inputsFrom = [ config.process-compose.devServices.services.outputs.devShell ];

                packages = [
                  # elixir
                  beamPackages.erlang
                  beamPackages.elixir
                  beamPackages.hex
                  pkgs.next-ls
                  (inputs'.expert.packages.expert.override { inherit beamPackages; })

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
                  config.process-compose.devServices.services.postgres.postgres1.package
                  config.process-compose.devServices.outputs.package
                  pkgs.sd-switch
                  pkgs.entr
                ]
                ++ lib.optionals pkgs.stdenv.isLinux [
                  # elixir
                  pkgs.inotify-tools
                ];

                shellHook = ''
                  export PC_CONFIG_FILES=${config.process-compose.devServices.outputs.settingsFile}

                  mkdir -vp _build

                  ln -sf ${lib.getExe pkgs.tailwindcss_3} _build/tailwind-${os}-${arch}
                  ln -sf ${lib.getExe pkgs.esbuild} _build/esbuild-${os}-${arch}
                '';

                # go delve fix
                hardeningDisable = [ "fortify" ];
              };
            };

            checks = lib.optionalAttrs pkgs.stdenv.isLinux {
              default = pkgs.callPackage ./nix/tests/e2e.nix {
                flake = self;
              };
              services = pkgs.callPackage ./nix/tests/services.nix {
                flake = self;
              };
            };

            packages = rec {
              cli = pkgs.callPackage ./nix/packages/cli.nix {
                inherit beamPackages version;
              };

              go-cli = pkgs.callPackage ./nix/packages/go-cli.nix {
                inherit version;
              };

              agent = pkgs.callPackage ./nix/packages/agent.nix {
                inherit beamPackages version;
              };

              server = pkgs.callPackage ./nix/packages/server.nix {
                inherit
                  beamPackages
                  version
                  sowerServicesHook
                  ;

                sowerLib = self.lib;
              };

              sowerServicesHook = pkgs.callPackage ./nix/packages/services-hook.nix { };

              tests-simple-service = pkgs.callPackage ./nix/tests/simple-service.nix {
                inherit sowerServicesHook;
                sowerLib = self.lib;
              };
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
      }
    );
}
