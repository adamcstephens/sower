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
  '';

  meta.mainProgram = "sower";
}
