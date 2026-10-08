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
    let
      guestKernelPackages = import ../image/kernel.nix {
        inherit (pkgs) lib;
        inherit pkgs;
      };
      supportedImage = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
      stockImage =
        if supportedImage then self.lib.mkImage { system = pkgs.stdenv.hostPlatform.system; } else null;
    in
    {
      checks = {
        ${if supportedImage then "guest-kernel-config" else null} = guestKernelPackages.guestConfigCheck;
        mix = pkgs.callPackage ./mix-checks.nix {
          inherit beamPackages version;
        };
        cloud-hypervisor = pkgs.callPackage ./cloud-hypervisor.nix {
          inherit beamPackages;
        };
      };

      packages = rec {
        activator = cli;
        ${if supportedImage then "guest-kernel" else null} = guestKernelPackages.kernel;
        ${if supportedImage then "image" else null} = stockImage;
        guest = pkgs.callPackage ./guest.nix {
          inherit craneLib;
        };

        cli = pkgs.callPackage ./cli.nix {
          inherit craneLib;
        };

        cli-static = pkgs.callPackage ./cli.nix {
          craneLib = inputs.crane.mkLib pkgs.pkgsCross.musl64;
          extraArgs = {
            CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
            CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";

            cargoExtraArgs = "--target x86_64-unknown-linux-musl";
          };
        };

        garden = pkgs.callPackage ./garden.nix {
          inherit beamPackages version;
          inherit stockImage;
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
        seed-manifest-validator = pkgs.callPackage ./seed-manifest-validator.nix { };
      };
    };
}
