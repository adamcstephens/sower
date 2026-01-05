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

  vendorHash = "sha256-Ct7urD4IrXEcvNEqGUtaKqyr4M6S7ZEpuQQIUb91dIM=";

  meta.mainProgram = "sower";
}
