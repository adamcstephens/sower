{
  beamPackages,
  callPackages,
  lib,
  rustPlatform,
  util-linux,
}:

callPackages ./deps.nix {
  inherit lib beamPackages;
  overrides = self: prev: {
    rexec = prev.rexec.override (
      old:
      let
        native = rustPlatform.buildRustPackage {
          pname = "rexec-native";
          version = old.version;
          src = "${old.src}/native/rexec_native";
          cargoLock.lockFile = "${old.src}/native/rexec_native/Cargo.lock";
          nativeCheckInputs = [ util-linux ];
        };
      in
      {
        preBuild = ''
          mkdir -p priv/
          cp ${native}/bin/rexec_native priv/
        '';
      }
    );

    esbuild = prev.esbuild.override (old: {
      patches = [ ./esbuild-loadpaths.patch ];
    });

    tailwind = prev.tailwind.override (old: {
      patches = [ ./tailwind-loadpaths.patch ];
    });
  };
}
