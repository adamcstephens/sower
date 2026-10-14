defmodule CloudHypervisor.ConfigTest do
  use ExUnit.Case, async: true

  alias CloudHypervisor.{CLI, Config, Launch}
  alias CloudHypervisor.Config.{CPUs, Disk, LandlockRule, Net, Output, RNG, Vsock}

  test "omits optional settings rather than replacing native defaults" do
    config = %Config{kernel: "/kernel"}
    assert Config.to_api(config) == %{"payload" => %{"kernel" => "/kernel"}}

    assert CLI.command(%Launch{}, config) ==
             {"cloud-hypervisor", ["--seccomp", "true", "--kernel", "/kernel"]}
  end

  test "preserves byte units, boot arguments, explicit false values and repeated devices" do
    config = %Config{
      kernel: "/boot/kernel file",
      initramfs: "/boot/initramfs",
      cmdline: "console=ttyS0 root=/dev/vda rw",
      cpus: %CPUs{boot_vcpus: 2, max_vcpus: 4},
      memory: 134_221_824,
      disks: [
        %Disk{path: "/root image", image_type: :raw, readonly: false},
        %Disk{path: "/data", readonly: true}
      ],
      net: [
        %Net{tap: "sow-tap0", mac: "02:00:00:00:00:01"},
        %Net{tap: "sow-tap1", mac: "02:00:00:00:00:02"}
      ],
      serial: %Output{mode: :file, file: "/serial output"},
      console: %Output{mode: :off},
      rng: %RNG{src: "/dev/urandom"},
      vsock: %Vsock{cid: 42, socket: "/vsock socket"},
      landlock: true,
      landlock_rules: [
        %LandlockRule{path: "/boot", access: "r"},
        %LandlockRule{path: "/data", access: "rw"}
      ]
    }

    assert Config.to_api(config) == %{
             "payload" => %{
               "kernel" => "/boot/kernel file",
               "initramfs" => "/boot/initramfs",
               "cmdline" => "console=ttyS0 root=/dev/vda rw"
             },
             "cpus" => %{"boot_vcpus" => 2, "max_vcpus" => 4},
             "memory" => %{"size" => 134_221_824},
             "disks" => [
               %{"path" => "/root image", "image_type" => "Raw", "readonly" => false},
               %{"path" => "/data", "readonly" => true}
             ],
             "net" => [
               %{"tap" => "sow-tap0", "mac" => "02:00:00:00:00:01"},
               %{"tap" => "sow-tap1", "mac" => "02:00:00:00:00:02"}
             ],
             "serial" => %{"mode" => "File", "file" => "/serial output"},
             "console" => %{"mode" => "Off"},
             "rng" => %{"src" => "/dev/urandom"},
             "vsock" => %{"cid" => 42, "socket" => "/vsock socket"},
             "landlock_enable" => true,
             "landlock_rules" => [
               %{"path" => "/boot", "access" => "r"},
               %{"path" => "/data", "access" => "rw"}
             ]
           }

    assert CLI.command(%Launch{}, config) ==
             {"cloud-hypervisor",
              [
                "--seccomp",
                "true",
                "--kernel",
                "/boot/kernel file",
                "--initramfs",
                "/boot/initramfs",
                "--cmdline",
                "console=ttyS0 root=/dev/vda rw",
                "--cpus",
                "boot=2,max=4",
                "--memory",
                "size=134221824",
                "--disk",
                "path=/root image,readonly=off,image_type=raw",
                "path=/data,readonly=on",
                "--net",
                "tap=sow-tap0,mac=02:00:00:00:00:01",
                "tap=sow-tap1,mac=02:00:00:00:00:02",
                "--serial",
                "file=/serial output",
                "--console",
                "off",
                "--rng",
                "src=/dev/urandom",
                "--vsock",
                "cid=42,socket=/vsock socket",
                "--landlock",
                "--landlock-rules",
                "path=/boot,access=r",
                "path=/data,access=rw"
              ]}
  end

  test "explicitly disabled Landlock is false in JSON and absent from CLI" do
    config = %Config{kernel: "/kernel", landlock: false}
    assert Config.to_api(config)["landlock_enable"] == false

    assert CLI.command(%Launch{}, config) ==
             {"cloud-hypervisor", ["--seccomp", "true", "--kernel", "/kernel"]}
  end

  test "socket output uses the native socket field in both contracts" do
    config = %Config{kernel: "/kernel", serial: %Output{mode: :socket, socket: "/serial"}}
    assert Config.to_api(config)["serial"] == %{"mode" => "Socket", "socket" => "/serial"}
    assert {_, args} = CLI.command(%Launch{}, config)
    assert Enum.take(args, -2) == ["--serial", "socket=/serial"]
  end

  test "API projection rejects virtio-console socket mode rather than substituting a mode" do
    config = %Config{kernel: "/kernel", console: %Output{mode: :socket, socket: "/console"}}

    assert_raise ArgumentError, fn ->
      Config.to_api(config)
    end
  end
end
