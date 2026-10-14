{
  lib,
  pkgs,
  kernel,
}:
let
  required = {
    y = [
      "64BIT"
      "X86_64"
      "PCI"
      "ACPI"
      "VIRTIO"
      "VIRTIO_PCI"
      "VIRTIO_BLK"
      "VIRTIO_CONSOLE"
      "NET"
      "INET"
      "PACKET"
      "NETDEVICES"
      "VIRTIO_NET"
      "VSOCKETS"
      "VIRTIO_VSOCKETS"
      "BLK_DEV_INITRD"
      "RD_ZSTD"
      "DEVTMPFS"
      "BINFMT_ELF"
      "BINFMT_SCRIPT"
      "UNIX"
      "TTY"
      "SERIAL_8250"
      "SERIAL_8250_CONSOLE"
      "EXT4_FS"
      "OVERLAY_FS"
      "EROFS_FS"
      "EROFS_FS_ZIP"
      "LZ4_DECOMPRESS"
      "AUTOFS_FS"
      "TMPFS"
      "TMPFS_POSIX_ACL"
      "TMPFS_XATTR"
      "PROC_FS"
      "SYSFS"
      "INOTIFY_USER"
      "SIGNALFD"
      "TIMERFD"
      "EPOLL"
      "FHANDLE"
      "CGROUPS"
      "CGROUP_SCHED"
      "CPUSETS"
      "MEMCG"
      "CGROUP_PIDS"
      "NAMESPACES"
      "UTS_NS"
      "IPC_NS"
      "USER_NS"
      "PID_NS"
      "NET_NS"
      "SECCOMP"
      "SECCOMP_FILTER"
      "BPF_SYSCALL"
      "SECURITY"
      "RANDOMIZE_BASE"
      "STACKPROTECTOR_STRONG"
      "STRICT_KERNEL_RWX"
      "STRICT_MODULE_RWX"
    ];
    n = [
      "DRM"
      "SOUND"
      "USB_SUPPORT"
      "SCSI"
      "ATA"
      "BLK_DEV_NVME"
      "WLAN"
      "HID_SUPPORT"
      "KVM"
      "ISO9660_FS"
      "NFS_FS"
      "F2FS_FS"
      "ZRAM"
    ];
  };
in
pkgs.runCommand "sower-guest-kernel-config-check" { } ''
  fail=0
  ${lib.concatMapStringsSep "\n" (symbol: ''
    if ! grep --fixed-strings --line-regexp --quiet 'CONFIG_${symbol}=y' ${kernel.configfile}; then
      echo 'expected CONFIG_${symbol}=y'
      fail=1
    fi
  '') required.y}
  ${lib.concatMapStringsSep "\n" (symbol: ''
    if ! grep --fixed-strings --line-regexp --quiet '# CONFIG_${symbol} is not set' ${kernel.configfile}; then
      echo 'expected explicit CONFIG_${symbol} unset'
      fail=1
    fi
  '') required.n}
  if [ "$fail" -ne 0 ]; then
    echo 'guest kernel config assertion failed'
    exit 1
  fi
  touch "$out"
''
