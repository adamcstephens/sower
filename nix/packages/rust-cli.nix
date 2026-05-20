{
  craneLib,
  installShellFiles,
  lib,
}:

let
  src =
    with lib.fileset;
    toSource {
      root = ../..;
      fileset = unions [
        ../../Cargo.toml
        ../../Cargo.lock
        ../../build.rs
        ../../openapi.json
        ../../src
      ];
    };

  commonArgs = {
    inherit src;
    pname = "sower";
    version = (lib.importTOML ../../Cargo.toml).package.version;
    strictDeps = true;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    nativeBuildInputs = [
      installShellFiles
    ];

    postInstall = ''
      installShellCompletion --cmd sower \
        --bash <(COMPLETE=bash $out/bin/sower) \
        --fish <(COMPLETE=fish $out/bin/sower) \
        --zsh <(COMPLETE=zsh $out/bin/sower)

      # Symlink for use as a unique binary name (avoids PATH conflicts with the
      # Elixir `sower` CLI). When invoked via this symlink, the binary detects
      # argv[0] and routes to the `activator` subcommand.
      ln --symbolic sower $out/bin/sower-activator
    '';

    meta.mainProgram = "sower";
  }
)
