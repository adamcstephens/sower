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
    sower.seed.buildTypes = lib.mkOption {
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
    flake.flakeModules.seed = ./part.nix;
    flake.sower =
      let
        perSystemTopToSower =
          top:
          let
            systemTops = lib.mapAttrs (on: ov: (lib.mapAttrs (n: v: n) ov)) top;
            allTops =
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
                systemTops;
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
            allTops;
      in
      {
        dev-shell =
          lib.optionalAttrs (builtins.elem "devShells" cfg.buildTypes) perSystemTopToSower
            self.devShells;
        darwin =
          lib.optionalAttrs (builtins.elem "darwinConfigurations" cfg.buildTypes) lib.mapAttrs
            (n: v: { systems = [ v.pkgs.hostPlatform.system ]; })
            self.darwinConfigurations;
        home-manager =
          lib.optionalAttrs (builtins.elem "homeConfigurations" cfg.buildTypes) lib.mapAttrs
            (n: v: { systems = [ v.pkgs.hostPlatform.system ]; })
            self.homeConfigurations;
        nixos =
          lib.optionalAttrs (builtins.elem "devShells" cfg.buildTypes) lib.mapAttrs
            (n: v: { systems = [ v.pkgs.hostPlatform.system ]; })
            self.nixosConfigurations;
        package =
          lib.optionalAttrs (builtins.elem "packages" cfg.buildTypes) perSystemTopToSower
            self.packages;
      };
  };
}
