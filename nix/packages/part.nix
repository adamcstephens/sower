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
      packages = rec {
        activator = rust-cli;

        cli = pkgs.callPackage ./cli.nix {
          inherit activator beamPackages version;
        };

        garden = pkgs.callPackage ./garden.nix {
          inherit beamPackages version;
        };

        rust-cli = pkgs.callPackage ./rust-cli.nix {
          inherit craneLib;
        };

        server = pkgs.callPackage ./server.nix {
          inherit beamPackages version sowerServicesHook;

          sowerLib = self.lib;
        };

        sowerServicesHook = pkgs.callPackage ./services-hook.nix { };
      };
    };
}
