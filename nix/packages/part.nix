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
        rexec-native = pkgs.callPackage ./rexec-native.nix {
          inherit version;
        };

        activator = pkgs.callPackage ./activator.nix {
          inherit version;
        };

        cli = pkgs.callPackage ./cli.nix {
          inherit
            activator
            beamPackages
            rexec-native
            version
            ;
        };

        go-cli = pkgs.callPackage ./go-cli.nix {
          inherit version;
        };

        garden = pkgs.callPackage ./garden.nix {
          inherit beamPackages rexec-native version;
        };

        server = pkgs.callPackage ./server.nix {
          inherit
            beamPackages
            rexec-native
            version
            sowerServicesHook
            ;

          sowerLib = self.lib;
        };

        sowerServicesHook = pkgs.callPackage ./services-hook.nix { };
      };
    };
}
