{ lib, self, ... }:
{
  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    {
      checks = lib.optionalAttrs pkgs.stdenv.isLinux {
        default = pkgs.callPackage ./e2e.nix {
          flake = self;
        };
        services = pkgs.callPackage ./services.nix {
          flake = self;
        };
      };

      packages = {
        tests-simple-service = pkgs.callPackage ./simple-service.nix {
          inherit (self'.packages) sowerServicesHook;
          sowerLib = self.lib;
        };
      };
    };
}
