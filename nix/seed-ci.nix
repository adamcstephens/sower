{
  lib,
  makeWrapper,
  runCommandNoCC,

  attic,
  coreutils,
  nix,
  nix-eval-jobs,
  nushell,
}:
runCommandNoCC "seed-ci"
  {
    nativeBuildInputs = [ makeWrapper ];
    buildInputs = [ nushell ];
  }
  ''
    mkdir -p $out/bin
    cp ${../bin/seed-ci} $out/bin/seed-ci
    patchShebangs $out/bin

    wrapProgram $out/bin/seed-ci --prefix PATH : ${
      lib.makeBinPath [
        attic
        coreutils
        nix
        nix-eval-jobs
      ]
    }
  ''
