{
  lib,
  buildGoModule,
  version,
}:
buildGoModule rec {
  pname = "sower";
  inherit version;

  src =
    with lib.fileset;
    toSource {
      root = ../..;
      fileset = unions [
        ../../client
        ../../cmd/client
        ../../go.mod
        ../../go.sum
        ../../openapi.json
      ];
    };

  env.CGO_ENABLED = 0;

  ldflags = [ "-X main.version=${version}" ];

  postInstall = ''
    mv $out/bin/client $out/bin/sower
  '';

  # disable checks for now until better fleshed out
  doCheck = false;

  vendorHash = "sha256-y/AjhjrNc1670oGC22iLXDvjWzbgnhuMy6m6OE4upyY=";

  meta.mainProgram = "sower";
}
