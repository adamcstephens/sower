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

  vendorHash = "sha256-L9rk/6WH9vOgawNqC2MLRjOBblZuJG8ABCP+tYL35sI=";
}
