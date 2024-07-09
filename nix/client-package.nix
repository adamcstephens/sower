{
  lib,

  craneLib,
  darwin,
  libiconv,
  rustTarget,
  stdenv,
}:

craneLib.buildPackage (
  craneLib.crateNameFromCargoToml { cargoToml = ../client/Cargo.toml; }
  // {
    src =
      with lib.fileset;
      toSource {
        root = ./..;
        fileset = unions [
          ../client
          ../Cargo.lock
          ../Cargo.toml
        ];
      };
    strictDeps = true;

    CARGO_BUILD_TARGET = rustTarget;
    CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";

    buildInputs = lib.optionals stdenv.isDarwin [
      libiconv
      darwin.apple_sdk.frameworks.SystemConfiguration
    ];

    doNotRemoveReferencesToVendorDir = stdenv.isDarwin;

    meta.mainProgram = "sower";
  }
)
