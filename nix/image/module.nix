{
  config,
  lib,
  pkgs,
  modulesPath,
  imageIdentity,
  guest,
  guestKernelPackages,
  ...
}:
let
  overlay = path: {
    neededForBoot = true;
    overlay = {
      lowerdir = [ path ];
      upperdir = "/scratch/upper${path}";
      workdir = "/scratch/work${path}";
    };
  };
  fileSystems = {
    "/" = {
      device = "/dev/vda";
      fsType = "erofs";
      options = [ "ro" ];
    };
    "/scratch" = {
      device = "/dev/vdb";
      fsType = "ext4";
      options = [
        "nodev"
        "nosuid"
      ];
      neededForBoot = true;
    };
    "/nix/store" = lib.recursiveUpdate (overlay "/nix/store") {
      overlay.lowerdir = [ "/nix/.ro-store" ];
    };
  }
  // lib.genAttrs [
    "/etc"
    "/var"
    "/nix/var"
    "/root"
    "/home"
    "/tmp"
    "/bin"
    "/usr/bin"
  ] overlay;
in
{
  imports = [
    "${modulesPath}/profiles/headless.nix"
    "${modulesPath}/profiles/image-based-appliance.nix"
  ];

  system.stateVersion = "25.11";
  # This guest has no login service; its accounts remain locked.
  users.allowNoPasswordLogin = true;
  boot = {
    kernelPackages = lib.mkForce guestKernelPackages;
    kernelParams = lib.mkForce [
      "console=ttyS0"
      "panic=1"
      "root=fstab"
    ];
    loader.grub.enable = lib.mkForce false;
    initrd = {
      systemd.enable = lib.mkForce true;
      systemd.root = lib.mkForce "fstab";
      includeDefaultModules = lib.mkForce false;
      availableKernelModules = lib.mkForce [ ];
      kernelModules = lib.mkForce [ ];
    };
    supportedFilesystems = lib.mkForce {
      erofs = true;
      ext4 = true;
      overlay = true;
    };
  };
  fileSystems = lib.mkForce fileSystems;
  networking = {
    hostName = "sower-guest";
    firewall.enable = lib.mkForce false;
    useDHCP = lib.mkForce false;
    useNetworkd = lib.mkForce false;
    resolvconf.enable = lib.mkForce false;
    networkmanager.enable = lib.mkForce false;
    wireless.enable = lib.mkForce false;
  };
  services.timesyncd.enable = false;
  services.getty.enable = lib.mkDefault false;
  services.userborn.enable = lib.mkDefault true;
  services.userborn.importLegacyState = lib.mkDefault false;
  console.enable = lib.mkDefault false;
  system.tools =
    lib.genAttrs
      [
        "nixos-build-vms"
        "nixos-enter"
        "nixos-generate-config"
        "nixos-install"
        "nixos-option"
        "nixos-rebuild"
      ]
      (_: {
        enable = lib.mkDefault false;
      });
  environment.defaultPackages = [ ];
  environment.systemPackages = [
    pkgs.bash
    pkgs.coreutils
  ];
  environment.etc."sower/image.json" = {
    enable = lib.mkForce true;
    text = lib.mkForce (builtins.toJSON imageIdentity);
  };
  environment.etc."udev/hwdb.bin".enable = lib.mkDefault false;
  nix = {
    enable = lib.mkForce true;
    channel.enable = false;
    settings = {
      require-sigs = lib.mkForce true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };
  systemd.defaultUnit = lib.mkForce "sower-execution.target";
  systemd.targets.sower-execution = lib.mkForce {
    enable = true;
    requires = [
      "multi-user.target"
      "sower-guest.service"
    ];
    after = [
      "multi-user.target"
      "sower-guest.service"
    ];
  };
  systemd.services.sower-register = lib.mkForce {
    enable = true;
    unitConfig.DefaultDependencies = false;
    requiredBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "nix-daemon.socket"
      "nix-daemon.service"
    ];
    after = [ "local-fs.target" ];
    requires = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for parameter in $(cat /proc/cmdline); do
        case "$parameter" in
          sower.registration=*) registration="''${parameter#sower.registration=}" ;;
        esac
      done
      test -n "$registration"
      ${config.nix.package}/bin/nix-store --load-db < "$registration"
    '';
  };
  systemd.services.sower-network = lib.mkForce {
    enable = true;
    requires = [ "systemd-udev-trigger.service" ];
    after = [ "systemd-udev-trigger.service" ];
    before = [ "sower-guest.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      address= gateway= dns= mac=
      network_requested=false
      for parameter in $(cat /proc/cmdline); do
        case "$parameter" in
          sower.network.address=*|sower.network.gateway=*|sower.network.dns=*|sower.network.mac=*)
            network_requested=true ;;
        esac
        case "$parameter" in
          sower.network.address=*) address="''${parameter#sower.network.address=}" ;;
          sower.network.gateway=*) gateway="''${parameter#sower.network.gateway=}" ;;
          sower.network.dns=*) dns="''${parameter#sower.network.dns=}" ;;
          sower.network.mac=*) mac="''${parameter#sower.network.mac=}" ;;
        esac
      done
      if [ "$network_requested" = false ]; then
        exit 0
      fi
      ipv4() {
        local octet
        local -a octets
        [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        IFS=. read -r -a octets <<< "$1"
        for octet in "''${octets[@]}"; do
          [ "''${#octet}" -le 3 ] && [ "$((10#$octet))" -le 255 ] || return 1
        done
      }
      [[ "$address" == */30 ]]
      ipv4 "''${address%/30}"
      ipv4 "$gateway"
      ipv4 "$dns"
      [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
      # Wait for enumeration and interface renames before selecting by MAC.
      ${config.systemd.package}/bin/udevadm settle --timeout=30
      interface=
      for device in /sys/class/net/*; do
        read -r device_mac < "$device/address"
        if [ "$device_mac" = "''${mac,,}" ]; then
          interface="''${device##*/}"
          break
        fi
      done
      test -n "$interface"
      ${pkgs.iproute2}/bin/ip link set dev "$interface" up
      ${pkgs.iproute2}/bin/ip address replace "$address" dev "$interface"
      ${pkgs.iproute2}/bin/ip route replace default via "$gateway" dev "$interface"
      printf 'nameserver %s\n' "$dns" > /etc/resolv.conf
    '';
  };
  systemd.services.sower-guest = lib.mkForce {
    enable = true;
    requires = [
      "sower-register.service"
      "sower-network.service"
      "multi-user.target"
    ];
    after = [
      "sower-register.service"
      "sower-network.service"
      "multi-user.target"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${guest}/bin/sower-guest";
      Restart = "no";
    };
  };
}
