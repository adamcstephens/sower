{
  cli,
  lib,
  makeWrapper,
  rust-cli,
  symlinkJoin,
}:

# The Rust CLI is the front door; its `build` subcommand execs `sower-cli`
# from PATH. Composed here instead of wrapping rust-cli directly so the
# activator package (= rust-cli) keeps a lean closure.
symlinkJoin {
  pname = "sower";
  inherit (rust-cli) version;

  paths = [ rust-cli ];

  nativeBuildInputs = [ makeWrapper ];

  postBuild = ''
    wrapProgram $out/bin/sower --suffix PATH : ${lib.makeBinPath [ cli ]}
  '';

  meta.mainProgram = "sower";
}
