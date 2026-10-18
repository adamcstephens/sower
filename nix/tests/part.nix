{ lib, self, ... }:
{
  perSystem =
    {
      beamPackages,
      pkgs,
      self',
      ...
    }:
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        default = pkgs.callPackage ./e2e.nix {
          flake = self;
        };
        services = pkgs.callPackage ./services.nix {
          flake = self;
        };
        ${if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "execution" else null} =
          pkgs.callPackage ./execution.nix
            { flake = self; };
        ${if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "image" else null} =
          pkgs.callPackage ./image.nix
            {
              flake = self;
              inherit beamPackages;
            };
      };

      packages = {
        tests-simple-service = pkgs.callPackage ./simple-service.nix {
          inherit (self'.packages) sowerServicesHook;
          sowerLib = self.lib;
        };
        tests-seed-manifest = pkgs.callPackage ./seed-manifest.nix {
          sowerLib = self.lib;
        };
      };
    };
}
