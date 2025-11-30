{
  lib,
  makeWrapper,
  runCommand,

  attic-client,
  coreutils,
  nushell,
}:
runCommand "seed-ci"
  {
    nativeBuildInputs = [ makeWrapper ];
    buildInputs = [ nushell ];
  }
  ''
    mkdir -p $out/bin
    cp ${../../bin/seed-ci} $out/bin/seed-ci
    patchShebangs $out/bin

    wrapProgram $out/bin/seed-ci --prefix PATH : ${
      lib.makeBinPath [
        attic-client
        coreutils
      ]
    }
  ''
