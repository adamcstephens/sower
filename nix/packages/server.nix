{
  inputs,
  lib,
  pkgs,
  callPackages,
  beamPackages,
  elixir,
  esbuild,
  rustPlatform,
  tailwindcss,
  stdenv,
  version,
}:
let
  arch = if stdenv.isAarch64 then "arm64" else "x64";
  os = if stdenv.isDarwin then "darwin" else "linux";
  pkgs' = pkgs;

  generateUnitFiles =
    {
      pkgs,
      config,
    }:
    let
      moduler = lib.evalModules {
        modules = [
          {
            config._module.args = {
              inherit pkgs;
            };
          }
          (
            {
              config,
              lib,
              ...
            }:
            let
              utils = import "${inputs.nixpkgs}/nixos/lib/utils.nix" {
                inherit config lib pkgs;
              };

              inherit (utils) systemdUtils;

              inherit (systemdUtils.lib)
                generateUnits
                targetToUnit
                serviceToUnit
                socketToUnit
                timerToUnit
                pathToUnit
                mountToUnit
                automountToUnit
                sliceToUnit
                ;

              inherit (lib)
                listToAttrs
                literalExpression
                mkEnableOption
                mkOption
                mkPackageOption
                types
                mapAttrs'
                ;

              cfg = config.systemd;
            in
            {
              options = {
                service-units = lib.mkOption {
                  # TODO type this
                };

                systemd = {
                  package = mkPackageOption pkgs "systemd" { };

                  enableStrictShellChecks = mkEnableOption "" // {
                    description = "Whether to run shellcheck on the generated scripts for systemd units.";
                  };

                  units = mkOption {
                    description = "Definition of systemd units; see {manpage}`systemd.unit(5)`.";
                    default = { };
                    type = systemdUtils.types.units;
                  };

                  packages = mkOption {
                    default = [ ];
                    type = types.listOf types.package;
                    example = literalExpression "[ pkgs.systemd-cryptsetup-generator ]";
                    description = "Packages providing systemd units and hooks.";
                  };

                  targets = mkOption {
                    default = { };
                    type = systemdUtils.types.targets;
                    description = "Definition of systemd target units; see {manpage}`systemd.target(5)`";
                  };

                  services = mkOption {
                    default = { };
                    type = systemdUtils.types.services;
                    description = "Definition of systemd service units; see {manpage}`systemd.service(5)`.";
                  };

                  sockets = mkOption {
                    default = { };
                    type = systemdUtils.types.sockets;
                    description = "Definition of systemd socket units; see {manpage}`systemd.socket(5)`.";
                  };

                  timers = mkOption {
                    default = { };
                    type = systemdUtils.types.timers;
                    description = "Definition of systemd timer units; see {manpage}`systemd.timer(5)`.";
                  };

                  paths = mkOption {
                    default = { };
                    type = systemdUtils.types.paths;
                    description = "Definition of systemd path units; see {manpage}`systemd.path(5)`.";
                  };

                  mounts = mkOption {
                    default = [ ];
                    type = systemdUtils.types.mounts;
                    description = ''
                      Definition of systemd mount units; see {manpage}`systemd.mount(5)`.

                      This is a list instead of an attrSet, because systemd mandates
                      the names to be derived from the `where` attribute.
                    '';
                  };

                  automounts = mkOption {
                    default = [ ];
                    type = systemdUtils.types.automounts;
                    description = ''
                      Definition of systemd automount units; see {manpage}`systemd.automount(5)`.

                      This is a list instead of an attrSet, because systemd mandates
                      the names to be derived from the `where` attribute.
                    '';
                  };

                  defaultUnit = mkOption {
                    default = "multi-user.target";
                    type = types.str;
                    description = ''
                      Default unit started when the system boots; see {manpage}`systemd.special(7)`.
                    '';
                  };

                  ctrlAltDelUnit = mkOption {
                    default = "reboot.target";
                    type = types.str;
                    example = "poweroff.target";
                    description = ''
                      Target that should be started when Ctrl-Alt-Delete is pressed;
                      see {manpage}`systemd.special(7)`.
                    '';
                  };

                  globalEnvironment = mkOption {
                    type =
                      with types;
                      attrsOf (
                        nullOr (oneOf [
                          str
                          path
                          package
                        ])
                      );
                    default = { };
                    example = {
                      TZ = "CET";
                    };
                    description = ''
                      Environment variables passed to *all* systemd units.
                    '';
                  };

                };
              };

              config = {
                systemd = {
                  package = pkgs.systemd;
                  defaultUnit = "default.target";
                  ctrlAltDelUnit = "reboot.target";

                  units =
                    let
                      withName = cfgToUnit: cfg: lib.nameValuePair cfg.name (cfgToUnit cfg);
                    in
                    mapAttrs' (_: withName serviceToUnit) cfg.services
                    // mapAttrs' (_: withName socketToUnit) cfg.sockets
                    // mapAttrs' (_: withName targetToUnit) cfg.targets
                    // mapAttrs' (_: withName timerToUnit) cfg.timers
                    // listToAttrs (map (withName mountToUnit) cfg.mounts)
                    // listToAttrs (map (withName automountToUnit) cfg.automounts);
                };
              };

            }
          )
          (
            {
              config,
              lib,
              pkgs,
              ...
            }:
            let
              utils = import "${inputs.nixpkgs}/nixos/lib/utils.nix" {
                inherit config lib pkgs;
              };
              upstreamUnits = [
                "basic.target"
              ];

              upstreamWants = [
                "multi-user.target.wants"
              ];

              system-units = utils.systemdUtils.lib.generateUnits {
                type = "system";
                inherit (config.systemd) units;
                inherit upstreamUnits upstreamWants;
                packages = [ ];
              };
            in
            {
              config = {
                service-units = pkgs.runCommand "service-units" { } ''
                  cp -R ${system-units} $out
                  chmod +w -R $out
                  find $out -xtype l -delete
                  find $out -type d -empty -delete
                  for unit in ${builtins.toString upstreamUnits}; do
                    rm $out/$unit
                  done
                '';
              };
            }
          )
          {
            systemd = config;
          }
        ];
        class = "sower_services";
      };

    in
    moduler.config.service-units;
in
beamPackages.mixRelease rec {
  pname = "sower";
  inherit version;

  inherit elixir;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../assets
      ../../config
      ../../lib
      ../../mix.exs
      ../../mix.lock
      ../../priv
      ../../test
      ../../VERSION
    ];
  };

  sowerServices = generateUnitFiles {
    inherit pkgs;
    config = {
      services.test = {
        wantedBy = [
          "default.target"
          "network-online.target"
          "multi-user.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "PLACEHOLDER_OUT/bin/sower";
        };
      };

      sockets.test-socket = {
        wantedBy = [ "sockets.target" ];
      };
    };
  };

  mixNixDeps = callPackages ./deps.nix {
    inherit lib beamPackages;
    overrides = _: prev: {
      argon2 = prev.argon2.override (
        old:
        let
          native = rustPlatform.buildRustPackage {
            pname = "argon2";
            version = old.version;
            src = "${old.src}/native";
            cargoHash = "sha256-D7mONUH6f/RmFwfx51sLr6XWlIELNTFPvFm9TrbEMl4=";
            useFetchCargoVendor = true;
          };
        in
        {
          # pre-build the make target
          preBuild = ''
            mkdir -p priv/
            cp ${native}/lib/libargon2.so priv/argon2_${old.version}.so
          '';

          # move native into expected location
          postInstall = ''
            mv $out/lib/erlang/lib/argon2-${old.version}/priv/argon2_${old.version}.so $out/lib/erlang/lib/argon2-${old.version}/priv/argon2.so
          '';
        }
      );

      esbuild = prev.esbuild.override (old: {
        patches = [ ./esbuild-loadpaths.patch ];
      });

      tailwind = prev.tailwind.override (old: {
        patches = [ ./tailwind-loadpaths.patch ];
      });
    };
  };

  postBuild = ''
    # prevent mix from trying to download binaries
    ln -sfv ${lib.getExe esbuild} _build/esbuild-${os}-${arch}
    ln -sfv ${lib.getExe tailwindcss} _build/tailwind-${os}-${arch}

    mix assets.deploy --no-deps-check
  '';

  preInstall = ''
    mkdir -p $out/.sower/systemd/system
    find ${sowerServices} -mindepth 1  -type d | while read dir; do
      cp --recursive $dir $out/.sower/systemd/system/
    done
    cp --dereference ${sowerServices}/* $out/.sower/systemd/system || true
    find $out/.sower/systemd/ -type f | while read unit; do
      chmod +w $unit
      sed -i "s,PLACEHOLDER_OUT,$out," $unit
    done
  '';

  # disabled because requires test deps to work
  # doCheck = true;
  # nativeCheckInputs = [
  #   postgresql
  #   postgresqlTestHook
  # ];
  # checkPhase = ''
  #   runHook preCheck
  #
  #   export MIX_ENV=test
  #
  #   ${nixpkgs}/pkgs/development/beam-modules/mix-configure-hook.sh
  #
  #   mix do deps.loadpaths --no-deps-check, test
  #
  #   runHook postCheck
  # '';

  passthru = {
    inherit mixNixDeps;
  };

  meta.mainProgram = "sower";
}
