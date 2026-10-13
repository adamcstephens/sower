{ inputs, lib }:
{
  system ? "x86_64-linux",
  modules ? [ ],
}:
assert lib.assertMsg (system == "x86_64-linux") "sower.lib.mkImage supports only x86_64-linux";
let
  pkgs = import inputs.nixpkgs { inherit system; };
  guestKernelPackages = import ./kernel.nix { inherit lib pkgs; };
  guest = pkgs.callPackage ../packages/guest.nix {
    craneLib = inputs.crane.mkLib pkgs;
  };
  imageIdentity = {
    inherit system;
    contract = 2;
    vsock_port = 5000;
    work_store_read_port = 5001;
    work_store_write_port = 5002;
  };
  imageModule = import ./module.nix;
  evaluate =
    extraModules:
    import "${inputs.nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      specialArgs = { inherit imageIdentity guest guestKernelPackages; };
      modules = [
        "${inputs.nixpkgs}/nixos/modules/profiles/minimal.nix"
        imageModule
      ]
      ++ extraModules;
    };
  base = evaluate [ ];
  evaluated = evaluate modules;
  config = evaluated.config;
  expected = imageModule {
    inherit
      config
      lib
      pkgs
      imageIdentity
      guest
      guestKernelPackages
      ;
    modulesPath = "${inputs.nixpkgs}/nixos/modules";
  };
  matches =
    wanted: actual:
    if lib.isDerivation wanted then
      wanted.outPath == actual.outPath
    else if builtins.isAttrs wanted && wanted ? kernel && lib.isDerivation wanted.kernel then
      matches wanted.kernel actual.kernel
    else if builtins.isAttrs wanted then
      lib.all (key: builtins.hasAttr key actual && matches wanted.${key} actual.${key}) (
        builtins.attrNames wanted
      )
    else
      wanted == actual;
  preservesForced =
    wanted: actual:
    if builtins.isAttrs wanted && (wanted._type or null) == "override" then
      matches wanted.content actual
    else if builtins.isAttrs wanted && !lib.isDerivation wanted then
      lib.all (key: preservesForced wanted.${key} actual.${key}) (builtins.attrNames wanted)
    else
      true;
  invariant =
    matches base.config.fileSystems config.fileSystems
    &&
      toString base.config.environment.etc."sower/image.json".source
      == toString config.environment.etc."sower/image.json".source
    && preservesForced (builtins.removeAttrs expected [
      "imports"
      "fileSystems"
    ]) config;
  closure = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
  packedClosure = pkgs.closureInfo {
    rootPaths = [
      config.system.build.toplevel
      closure
    ];
  };
  root =
    pkgs.runCommand "sower-root.erofs"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
        nativeBuildInputs = [
          pkgs.erofs-utils
          pkgs.gnutar
        ];
      }
      ''
        mkdir --parents root/nix/.ro-store root/nix/store root/nix/var root/etc root/var root/root root/home root/tmp root/bin root/usr/bin root/scratch root/proc root/sys root/dev root/run
        tar --create --absolute-names --verbatim-files-from \
          --transform 'flags=rSh;s|/nix/store/|nix/.ro-store/|' \
          --files-from ${packedClosure}/store-paths --directory root . \
          | mkfs.erofs --quiet --force-uid=0 --force-gid=0 -L sower-root \
            -U eb176051-bd15-49b7-9e6b-462e0b467019 -T 0 \
            --hard-dereference --tar=f -z lz4hc "$out"
      '';
  bootKernel = pkgs.runCommand "sower-boot-kernel" { } ''
    cp ${config.system.build.kernel}/${config.system.boot.loader.kernelFile} "$out"
  '';
  metadata = imageIdentity // {
    version = 1;
    kernel = "${bootKernel}";
    initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
    inherit root;
    cmdline = builtins.unsafeDiscardStringContext (
      lib.concatStringsSep " " (
        config.boot.kernelParams
        ++ [
          "ro"
          "init=${config.system.build.toplevel}/init"
          "sower.registration=${closure}/registration"
        ]
      )
    );
    scratch = {
      device = "/dev/vdb";
      label = "sower-scratch";
      filesystem = "ext4";
    };
  };
in
assert lib.assertMsg invariant
  "mkImage custom modules must preserve mandatory guest runtime, marker, root and boot configuration";
pkgs.runCommand "sower-image"
  {
    passthru = {
      inherit
        evaluated
        metadata
        root
        guest
        ;
      inherit (config.system.build) toplevel kernel initialRamdisk;
    };
  }
  ''
    mkdir --parents "$out"
    ln --symbolic ${metadata.kernel} "$out/kernel"
    ln --symbolic ${metadata.initrd} "$out/initrd"
    ln --symbolic ${root} "$out/root.erofs"
    cp ${pkgs.writeText "sower-boot.json" (builtins.toJSON metadata)} "$out/boot.json"
  ''
