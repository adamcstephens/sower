{
  bashNonInteractive,
  coreutils,
  craneLib,
  lib,
}:

let
  src =
    with lib.fileset;
    toSource {
      root = ../..;
      fileset = unions [
        ../../Cargo.toml
        ../../Cargo.lock
        ../../build.rs
        ../../openapi.json
        ../../src
        ../../guest
      ];
    };
  commonArgs = {
    inherit src;
    pname = "sower-guest";
    version = (lib.importTOML ../../guest/Cargo.toml).package.version;
    strictDeps = true;
    cargoExtraArgs = "--package sower-guest";
  };
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;
    doCheck = true;
    nativeCheckInputs = [
      bashNonInteractive
      coreutils
    ];
    meta.mainProgram = "sower-guest";
  }
)
