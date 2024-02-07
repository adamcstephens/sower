{
  config,
  lib,
  self,
  ...
}:
let
  cfg = config.sower.seed;
in
{
  options = {
    sower.seed.buildOutputs = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "devShells"
          "darwinConfigurations"
          "homeConfigurations"
          "nixosConfigurations"
          "packages"
        ]
      );
      description = "Outputs to automatically expose";
      default = [
        "devShells"
        "darwinConfigurations"
        "homeConfigurations"
        "nixosConfigurations"
        "packages"
      ];
    };
  };

  config = {
    flake.flakeModules.seed = ./flakemodule.nix;

    flake.sower =
      let
        enabledOutput =
          let
            outputs = builtins.attrNames self;
          in
          output:
          (builtins.elem output outputs) && (builtins.elem output cfg.buildOutputs);

        nonSystemOutputToSower =
          output: lib.mapAttrs (n: v: { systems = [ v.pkgs.hostPlatform.system ]; }) output;

        perSystemOutputToSower =
          output:
          let
            systemOutputs = lib.mapAttrs (on: ov: (lib.mapAttrs (n: v: n) ov)) output;
            allOutputs =
              lib.foldlAttrs
                (
                  acc: n: v:
                  acc
                  ++
                    builtins.map
                      (dsv: {
                        name = dsv;
                        system = n;
                      })
                      (builtins.attrNames v)
                )
                [ ]
                systemOutputs;
          in
          lib.foldl
            (
              acc: n:
              acc
              // {
                "${n.name}" = {
                  systems = (acc.${n.name}.systems or [ ]) ++ [ n.system ];
                };
              }
            )
            { }
            allOutputs;
      in
      {
        dev-shell = lib.optionalAttrs (enabledOutput "devShells") (perSystemOutputToSower self.devShells);
        darwin = lib.optionalAttrs (enabledOutput "darwinConfigurations") (
          nonSystemOutputToSower self.darwinConfigurations
        );
        home-manager = lib.optionalAttrs (enabledOutput "homeConfigurations") (
          nonSystemOutputToSower self.homeConfigurations
        );
        nixos = lib.optionalAttrs (enabledOutput "nixosConfigurations") (
          nonSystemOutputToSower self.nixosConfigurations
        );
        package = lib.optionalAttrs (enabledOutput "packages") (perSystemOutputToSower self.packages);
      };
  };
}
