{
  lib,
  buildGoModule,
  makeWrapper,
  nix-eval-jobs,
  sd-switch,
  version,
}:
let
  nixpkgsref = lib.elemAt (lib.splitString "." lib.version) 3;
in

buildGoModule rec {
  pname = "sower-cli";
  inherit version;

  src =
    with lib.fileset;
    toSource {
      root = ../..;
      fileset = unions [
        ../../client-go
        ../../cmd/cli
        ../../go.mod
        ../../go.sum
        ../../openapi.json
      ];
    };

  nativeBuildInputs = [
    makeWrapper
  ];

  env.CGO_ENABLED = 0;

  ldflags = [
    "-X main.version=${version}"
    "-X main.nixpkgsref=${nixpkgsref}"
  ];

  postInstall = ''
    mv $out/bin/cli $out/bin/sower

    wrapProgram $out/bin/sower --prefix PATH : ${
      lib.makeBinPath [
        nix-eval-jobs
        sd-switch
      ]
    }
  '';

  # disable checks for now until better fleshed out
  doCheck = false;

  vendorHash = "sha256-tGnB8f0OKjrPcnoMXJfBnCn5ou71VPi6vz4EScEvQI8=";

  meta.mainProgram = "sower";
}
