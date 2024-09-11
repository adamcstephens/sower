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

  vendorHash = "sha256-X15e9mVrNPjvGxKGd33mmC/gnR2/DpbWcKw/lQW9nTk=";
}
