{
  lib,
  buildGoModule,
  version,
}:
let
  nixpkgsref = lib.elemAt (lib.splitString "." lib.version) 3;
in

buildGoModule rec {
  pname = "sower-activator";
  inherit version;

  src =
    with lib.fileset;
    toSource {
      root = ../..;
      fileset = unions [
        ../../cmd/sower-activator
        ../../go.mod
        ../../go.sum
      ];
    };

  env.CGO_ENABLED = 0;

  ldflags = [
    "-X main.version=${version}"
    "-X main.nixpkgsref=${nixpkgsref}"
  ];

  vendorHash = "sha256-+sHF3EMkTD7tPnD9DkbYCMMbbHl3urWSzRaA6KENBog=";

  meta.mainProgram = "sower";
}
