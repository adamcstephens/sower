{ lib, buildGoModule }:
buildGoModule rec {
  pname = "sower";
  version = builtins.readFile ../VERSION;

  src =
    with lib.fileset;
    toSource {
      root = ./..;
      fileset = unions [
        ../client
        ../cmd/client
        ../go.mod
        ../go.sum
        ../openapi.json
      ];
    };

  CGO_ENABLED = 0;

  ldflags = [ "-X main.version=${version}" ];

  postInstall = ''
    mv $out/bin/client $out/bin/sower
  '';

  # disable checks for now until better fleshed out
  doCheck = false;

  vendorHash = "sha256-F4cSZYrAb5COXNfBmDQvbBzax/FCRLPUOKYDq+g4MDM=";

  meta.mainProgram = "sower";
}
