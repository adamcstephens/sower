{
  cli,
  lib,
  makeWrapper,
  sower-build,
  symlinkJoin,
}:

symlinkJoin {
  pname = "sower";
  inherit (cli) version;

  paths = [ cli ];

  nativeBuildInputs = [ makeWrapper ];

  postBuild = ''
    wrapProgram $out/bin/sower --suffix PATH : ${lib.makeBinPath [ sower-build ]}
  '';

  meta.mainProgram = "sower";
}
