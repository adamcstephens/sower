{
  seed-ci,
  extra-substituters ? null,
  extra-trusted-public-keys ? null,

  lib,
  dockerTools,
  fetchgit,
  fetchurl,
  fetchFromGitHub,
  hostPlatform,
  writeTextFile,

  coreutils,
  nodejs,
}:
let
  nvfetcher = import ./_sources/generated.nix {
    inherit
      fetchgit
      fetchurl
      fetchFromGitHub
      dockerTools
      ;
  };
in
dockerTools.streamLayeredImage {
  name = "git.junco.dev/sower/seed-ci";

  fromImage = nvfetcher."nix-${hostPlatform.system}".src.outPath;
  tag = "latest-${hostPlatform.system}";

  # upstream nix image is using 100 layers already
  maxLayers = 115;

  contents = [
    seed-ci
    # act expects nodejs
    nodejs

    (writeTextFile {
      name = "nix.conf";
      destination = "/etc/nix/nix.conf";
      text = ''
        builders-use-substitutes = true
        experimental-features = nix-command flakes
        ${lib.optionalString (extra-substituters != null) extra-substituters}
        ${lib.optionalString (extra-trusted-public-keys != null) extra-trusted-public-keys}
        store = unix:///host/nix/var/nix/daemon-socket/socket?root=/host
      '';
    })
  ];

  # forgejo uses /bin/sleep as the entrypoint
  extraCommands = ''
    mkdir -p bin
    ln -s ${coreutils}/bin/sleep bin/sleep
  '';

  # replace the entire path so we can prepend /bin
  config.Env = [
    "PATH=/bin:/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/default/sbin"
    "NIX_EVAL_ARGS=--eval-store unix:///host/nix/var/nix/daemon-socket/socket?root=/host"
  ];
}
