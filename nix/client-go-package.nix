{ lib, buildGoModule }:
buildGoModule {
  pname = "sower-client";
  version = builtins.readFile ../VERSION;

  src =
    with lib.fileset;
    toSource {
      root = ./..;
      fileset = unions [
        ../client-go
        ../go.mod
        ../go.sum
      ];
    };

  CGO_ENABLED = 0;

  postInstall = ''
    mv $out/bin/client-go $out/bin/sower
  '';

  vendorHash = "sha256-PqhDYEoLD1ZBQjMgAIylZMHK8i5HQLdiotrFxEAoJHU=";
}
