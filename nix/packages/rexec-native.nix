{
  lib,
  rustPlatform,
  version,
}:

rustPlatform.buildRustPackage {
  pname = "rexec-native";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = ../../libs/rexec/native/rexec_native;
  };

  sourceRoot = "source/libs/rexec/native/rexec_native";

  cargoHash = lib.fakeHash;
}
