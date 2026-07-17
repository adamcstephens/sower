{ self, ... }:
{
  perSystem =
    {
      beamPackages,
      craneLib,
      pkgs,
      version,
      ...
    }:
    {
      checks = {
        mix = pkgs.callPackage ./mix-checks.nix {
          inherit beamPackages version;
        };
      };

      packages = rec {
        activator = cli;

        cli = pkgs.callPackage ./cli.nix {
          inherit craneLib;
        };

        garden = pkgs.callPackage ./garden.nix {
          inherit beamPackages version;
        };

        sower = pkgs.callPackage ./sower.nix {
          inherit cli sower-build;
        };

        sower-build = pkgs.callPackage ./sower-build.nix {
          inherit beamPackages version;
        };

        server = pkgs.callPackage ./server.nix {
          inherit beamPackages version sowerServicesHook;

          sowerLib = self.lib;
        };

        sowerServicesHook = pkgs.callPackage ./services-hook.nix { };
      };
    };
}
