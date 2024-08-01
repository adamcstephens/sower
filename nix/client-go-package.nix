{ lib, buildGoModule }:
buildGoModule rec {
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

  ldflags = [ "-X main.version=${version}" ];

  postInstall = ''
    mv $out/bin/client-go $out/bin/sower
  '';

  vendorHash = "sha256-7658me4SpEoO66Y16Qy3/ue6/AJTuwb2T1mS2OQGB64=";
}
