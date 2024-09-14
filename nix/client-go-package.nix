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

  # disable checks for now until better fleshed out
  doCheck = false;

  vendorHash = "sha256-EIequUi6sULf3PDwzrGMwJgquct1TOjt8uU1IN6dRJY=";
}
