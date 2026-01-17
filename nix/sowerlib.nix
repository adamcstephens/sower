{
  inputs,
  lib,
  supportedSystems ? [
    "x86_64-linux"
    "aarch64-linux"
  ],
}:
rec {
  mkSeed =
    {
      name,
      type,
      package,
      extraSeedMeta ? { },
    }:
    lib.addMetaAttrs {
      sower.seed = lib.recursiveUpdate {
        inherit name;
        seed_type = type;
      } extraSeedMeta;
    } package;

  mkSeedNixos =
    name: nixosConfig:
    lib.nameValuePair "nixos/${name}" (mkSeed {
      inherit name;
      package = nixosConfig.config.system.build.toplevel;
      type = "nixos";
      extraSeedMeta = nixosConfig.config.sower.seed.meta or { };
    });

  mkSeedHomeManager =
    name: homeConfig:
    lib.nameValuePair "home/${name}" (mkSeed {
      inherit name;
      type = "home-manager";
      package = homeConfig.activationPackage;
      extraSeedMeta = {
        tags = {
          inherit (homeConfig.config.home) username homeDirectory;
          inherit (homeConfig.config.home.version) release;
        };
      };
    });

  genNixosPackages =
    nixosConfigurations:
    let
      nixos =
        system:
        lib.pipe nixosConfigurations [
          (lib.filterAttrs (_: nixosConfig: nixosConfig.pkgs.stdenv.hostPlatform.system == system))
          (lib.mapAttrs' mkSeedNixos)
        ];
    in
    lib.listToAttrs (
      lib.map (system: {
        name = system;
        value = nixos system;
      }) supportedSystems
    );

  genHomeManagerPackages =
    homeConfigurations:
    let
      home =
        system:
        lib.pipe homeConfigurations [
          (lib.filterAttrs (_: homeConfig: homeConfig.pkgs.stdenv.hostPlatform.system == system))
          (lib.mapAttrs' mkSeedHomeManager)
        ];
    in
    lib.listToAttrs (
      lib.map (system: {
        name = system;
        value = home system;
      }) supportedSystems
    );

  prefixFlakeSystemOutputs =
    prefix: output:
    lib.pipe output [
      lib.attrNames
      (lib.foldl (
        acc: system:
        acc
        // (
          let
            finalOutput = lib.mapAttrs' (name: p: lib.nameValuePair "${prefix}/${name}" p) output.${system};
          in
          {
            "${system}" = finalOutput;
          }
        )
      ) { })
    ];

  # generateUnitFiles creates a derivation with systemd units
  # using the nixos module structure, but intended for using in
  # a sower service along with sowerServicesHook
  generateUnitFiles =
    {
      pkgs,
      config,
    }:
    let
      moduler = pkgs.lib.evalModules {
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
                targetToUnit
                serviceToUnit
                socketToUnit
                timerToUnit
                mountToUnit
                automountToUnit
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

                # copy the options structure out of nixpkgs, or a subset anyway
                # unfortunately this isn't exposed in a consumable way in nixpkgs
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
                # the bare minimum to init the necessary config, and merge all the units together
                # for consumption by generateUnits
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
                # build the combined units into a package, and expose
                # then in a module option for consumption
                service-units = pkgs.runCommand "service-units" { } ''
                  cp --recursive ${system-units} $out
                  chmod +w -R $out
                  # delete any broken links
                  find $out -xtype l -delete
                  # delete empty directories
                  find $out -type d -empty -delete
                  # remove the upstream targets
                  for unit in ${builtins.toString upstreamUnits}; do
                    rm $out/$unit
                  done
                '';
              };
            }
          )
          {
            # pass on the config from generateUnitFiles
            systemd = config;
          }
        ];
        class = "sower_services";
      };

    in
    # return back the units, aka the package with them
    moduler.config.service-units;
}
