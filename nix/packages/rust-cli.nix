{
  installShellFiles,
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "sower";
  version = (lib.importTOML ../../Cargo.toml).package.version;

  src =
    with lib.fileset;
    toSource {
      root = ../..;
      fileset = unions [
        ../../Cargo.toml
        ../../Cargo.lock
        ../../src
      ];
    };

  cargoLock.lockFile = ../../Cargo.lock;

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
