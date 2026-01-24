{ self, ... }:
{
  perSystem =
    {
      beamPackages,
      pkgs,
      version,
      ...
    }:
    {
      packages = rec {
        activator = pkgs.callPackage ./activator.nix {
          inherit version;
        };

        cli = pkgs.callPackage ./cli.nix {
          inherit beamPackages version;
        };

        go-cli = pkgs.callPackage ./go-cli.nix {
          inherit version;
        };

        agent = pkgs.callPackage ./agent.nix {
          inherit beamPackages version;
        };

        server = pkgs.callPackage ./server.nix {
          inherit
            beamPackages
            version
            sowerServicesHook
            ;

          sowerLib = self.lib;
        };

        sowerServicesHook = pkgs.callPackage ./services-hook.nix { };
      };
    };
}
