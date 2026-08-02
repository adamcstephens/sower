{ inputs, self, ... }:
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

        cli-static = pkgs.pkgsMusl.callPackage ./cli.nix {
          craneLib = inputs.crane.mkLib pkgs.pkgsCross.musl64;
          extraArgs = {
            CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
            CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";

            cargoExtraArgs = "--target x86_64-unknown-linux-musl";
          };
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
