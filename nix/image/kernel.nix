{ lib, pkgs }:
let
  on = lib.mkForce lib.kernel.yes;
  off = lib.mkForce lib.kernel.no;
  kernelPackages = pkgs.linuxPackagesFor (
    pkgs.linuxPackages.kernel.override {
      autoModules = false;
      preferBuiltin = true;
      ignoreConfigErrors = true;
      structuredExtraConfig = {
        PCI = on;
        ACPI = on;
        VIRTIO = on;
        VIRTIO_PCI = on;
        VIRTIO_MMIO = on;
        VIRTIO_BLK = on;
        VIRTIO_CONSOLE = on;
        VSOCKETS = on;
        VIRTIO_VSOCKETS = on;
        BLK_DEV_INITRD = on;
        RD_ZSTD = on;
        DEVTMPFS = on;
        BINFMT_ELF = on;
        BINFMT_SCRIPT = on;
        UNIX = on;
        TTY = on;
        SERIAL_8250 = on;
        SERIAL_8250_CONSOLE = on;

        EXT4_FS = on;
        OVERLAY_FS = on;
        EROFS_FS = on;
        EROFS_FS_ZIP = on;
        LZ4_DECOMPRESS = on;
        AUTOFS_FS = on;
        TMPFS = on;
        TMPFS_POSIX_ACL = on;
        TMPFS_XATTR = on;
        PROC_FS = on;
        SYSFS = on;
        INOTIFY_USER = on;
        SIGNALFD = on;
        TIMERFD = on;
        EPOLL = on;
        FHANDLE = on;

        CGROUPS = on;
        CGROUP_SCHED = on;
        CPUSETS = on;
        MEMCG = on;
        CGROUP_PIDS = on;
        NAMESPACES = on;
        UTS_NS = on;
        IPC_NS = on;
        USER_NS = on;
        PID_NS = on;
        NET_NS = on;
        SECCOMP = on;
        SECCOMP_FILTER = on;
        BPF_SYSCALL = on;
        SECURITY = on;
        RANDOMIZE_BASE = on;
        STACKPROTECTOR_STRONG = on;
        STRICT_KERNEL_RWX = on;
        STRICT_MODULE_RWX = on;

        DRM = off;
        FB = off;
        SOUND = off;
        WLAN = off;
        WIRELESS = off;
        RFKILL = off;
        USB_SUPPORT = off;
        HID_SUPPORT = off;
        SCSI = off;
        ATA = off;
        MD = off;
        BLK_DEV_DM = off;
        BLK_DEV_NVME = off;
        NVME_CORE = off;
        NVME_TARGET = off;
        INFINIBAND = off;
        HYPERV = off;
        XEN = off;
        X86_PLATFORM_DEVICES = off;
        CHROME_PLATFORMS = off;
        MFD_CROS_EC_DEV = off;
        FIRMWARE_ATTRIBUTES_CLASS = off;
        PLATFORM_PROFILE = off;
        DCDBAS = off;
        DELL_RBU = off;
        ACPI_WMI = off;
        INTEL_RAPL = off;
        INTEL_RAPL_CORE = off;
        X86_PKG_TEMP_THERMAL = off;
        ACPI_DPTF = off;
        DPTF_POWER = off;
        DPTF_PCH_FIVR = off;

        EFI = off;
        EFI_VARS_PSTORE = off;
        ISO9660_FS = off;
        JOLIET = off;
        SQUASHFS = off;
        NFS_FS = off;
        NFSD = off;
        SUNRPC = off;
        F2FS_FS = off;
        UDF_FS = off;
        ZRAM = off;
        KVM = off;
        KVM_INTEL = off;
        KVM_AMD = off;
        PTP_1588_CLOCK_KVM = off;

        NETDEVICES = on;
        NET = on;
        INET = on;
        PACKET = on;
        ETHERNET = off;
        VIRTIO_NET = on;
        VIRTIO_INPUT = off;
        VIRTIO_BALLOON = off;
        VIRTIO_FS = off;
        FUSE_FS = off;
        NETFILTER = off;
        IP_VS = off;
        NET_SCHED = off;
        NETCONSOLE = off;
        BONDING = off;
        HAMRADIO = off;
        VLAN_8021Q = off;
        TUN = off;
        IOSCHED_BFQ = off;
        DMI_SYSFS = off;
        FW_CFG_SYSFS = off;
        BLK_DEV_LOOP = off;
      };
    }
  );
  guestConfigCheck = import ./kernel-check.nix {
    inherit lib pkgs;
    inherit (kernelPackages) kernel;
  };
in
kernelPackages.extend (_: _: { inherit guestConfigCheck; })
