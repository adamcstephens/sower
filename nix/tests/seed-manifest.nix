{ pkgs, sowerLib }:
let
  target = pkgs.runCommand "seed-target" { } ''
    mkdir --parents "$out"
    echo ready > "$out/ready"
  '';
  system = pkgs.stdenv.hostPlatform.system;
  seedJobs = {
    "seed/example" = sowerLib.mkSeed {
      inherit pkgs target;
      name = "example";
      type = "nixos";
      tags = { inherit system; };
    };
  };
  seed = seedJobs."seed/example";
  meta =
    (pkgs.lib.evalModules {
      modules = [
        ../nixos/seed.nix
        {
          _module.args.pkgs = pkgs;
          sower.seed.meta = {
            name = "overridden";
            seed_type = "service";
            tags = {
              system = "overridden-system";
              nixos_version = "overridden-version";
              origin = "configuration";
            };
          };
        }
      ];
    }).config.sower.seed.meta;
  nixosConfig = {
    inherit pkgs;
    config.system.build.toplevel = target;
    config.system.nixos.version = "26.11";
    config.sower.seed.meta =
      (pkgs.lib.evalModules {
        modules = [
          ../nixos/seed.nix
          { _module.args.pkgs = pkgs; }
        ];
      }).config.sower.seed.meta;
  };
  nixosJobs =
    (sowerLib.genNixosPackages {
      example = nixosConfig;
      override = nixosConfig // {
        config = nixosConfig.config // {
          sower.seed = { inherit meta; };
        };
      };
    }).${system};
  nixosSeed = nixosJobs."nixos/example";
  overrideSeed = nixosJobs."nixos/override";
  homeJobs =
    (sowerLib.genHomeManagerPackages {
      example = {
        inherit pkgs;
        activationPackage = target;
        config.home = {
          username = "alice";
          homeDirectory = "/home/alice";
          version.release = "26.11";
        };
      };
    }).${system};
  homeSeed = homeJobs."home/example";
  closure = pkgs.closureInfo {
    rootPaths = [
      seed
      nixosSeed
      overrideSeed
      homeSeed
    ];
  };
  unsupportedMeta = nixosConfig // {
    config = nixosConfig.config // {
      sower.seed.meta.unsupported = true;
    };
  };
  unsupportedOption =
    (pkgs.lib.evalModules {
      modules = [
        ../nixos/seed.nix
        {
          _module.args.pkgs = pkgs;
          sower.seed.meta.unsupported = true;
        }
      ];
    }).config.sower.seed.meta;
  check = pkgs.writers.writePython3Bin "check-seed-manifest" {
    libraries = [ pkgs.python3Packages.jsonschema ];
  } (builtins.readFile ./seed-manifest-check.py);
in
assert builtins.attrNames nixosJobs == [
  "nixos/example"
  "nixos/override"
];
assert builtins.attrNames homeJobs == [ "home/example" ];
assert !(builtins.tryEval (sowerLib.mkSeedNixos "unsupported" unsupportedMeta).value.drvPath).success;
assert !(builtins.tryEval (builtins.deepSeq unsupportedOption true)).success;
pkgs.stdenv.mkDerivation {
  name = "seed-manifest-test";
  dontUnpack = true;
  nativeBuildInputs = [ check ];
  installPhase = ''
    check-seed-manifest "${seed}" "${target}" "${../seed-manifest.schema.json}" "${nixosSeed}" "${homeSeed}" "${system}" "${overrideSeed}" "${closure}/store-paths"
    touch "$out"
  '';
}
