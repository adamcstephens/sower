defmodule Garden.ImageTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "rejects an unsupported executor contract before resolving boot artifacts", %{tmp_dir: dir} do
    write_manifest(dir, %{"contract" => 3})

    assert {:error, {:unsupported_contract, 3}} = Garden.Image.load(dir)
  end

  for contract <- [1, 2] do
    test "accepts contract #{contract} before resolving boot artifacts", %{tmp_dir: dir} do
      write_manifest(dir, %{"contract" => unquote(contract)})

      assert {:error, {:invalid_boot_artifact, "kernel"}} = Garden.Image.load(dir)
    end
  end

  test "rejects an unsupported architecture before resolving boot artifacts", %{tmp_dir: dir} do
    write_manifest(dir, %{"system" => "aarch64-linux"})

    assert {:error, {:unsupported_system, "aarch64-linux"}} = Garden.Image.load(dir)
  end

  test "translates resolved artifacts and runtime policy into manager-owned configuration" do
    image = %Garden.Image{
      directory: "/nix/store/image",
      kernel: "/nix/store/kernel",
      initrd: "/nix/store/initrd",
      root: "/nix/store/root.erofs",
      cmdline: "console=ttyS0",
      contract: 2,
      network_config: :static
    }

    assert %VMManager.Config{
             id: "builder",
             kernel: "/nix/store/kernel",
             initrd: "/nix/store/initrd",
             disks: [
               %CloudHypervisor.Config.Disk{path: "/nix/store/root.erofs", readonly: true},
               %VMManager.Storage.EphemeralDisk{
                 name: "scratch.ext4",
                 filesystem: :ext4,
                 label: "sower-scratch"
               }
             ],
             cmdline: "console=ttyS0",
             guest: %VMManager.Config.SowerGuest{contract: 2, vsock_port: 5000},
             cpus: 2,
             network: %VMManager.Network{provider: Garden.VM.Network}
           } = Garden.Image.vm_config(image, "builder", cpus: 2, network: :full)
  end

  test "translates Garden-only storage options while retaining native disk order" do
    image = %Garden.Image{
      directory: "/image",
      kernel: "/kernel",
      initrd: "/initrd",
      root: "/root",
      cmdline: ""
    }

    disk = %CloudHypervisor.Config.Disk{path: "/data"}

    config =
      Garden.Image.vm_config(image, "vm", scratch_bytes: 4096, disks: [disk], network: :none)

    assert [
             %CloudHypervisor.Config.Disk{path: "/root"},
             %VMManager.Storage.EphemeralDisk{bytes: 4096},
             ^disk
           ] = config.disks

    assert config.network == nil
    assert %CloudHypervisor.Config.Output{mode: :file, file: "serial.log"} = config.serial
    assert %CloudHypervisor.Config.Vsock{cid: 3} = config.vsock
  end

  test "rejects full networking when the image does not implement static networking" do
    image = %Garden.Image{
      directory: "/image",
      kernel: "/kernel",
      initrd: "/initrd",
      root: "/root",
      cmdline: ""
    }

    assert_raise ArgumentError, "full networking requires static network image support", fn ->
      Garden.Image.vm_config(image, "unsupported", network: :full)
    end
  end

  test "rejects resolved managed launch leases before persisting definitions", %{tmp_dir: dir} do
    request = Garden.VM.Network.request(socket_path: "/activator.sock")
    config = %VMManager.Config{id: "managed", kernel: "/kernel", network: request}
    manager = start_supervised!({VMManager.Manager, state_directory: dir})

    assert {:ok, "managed"} = VMManager.define(config, manager)
    assert {:ok, before} = VMManager.Store.load(dir)
    resolved = %{config | network: %{request | lease: "released-lease"}}

    assert {:error, :unexpected_network_lease} = VMManager.Config.validate(resolved)

    assert {:error, :unexpected_network_lease} =
             VMManager.define(%{resolved | id: "invalid"}, manager)

    assert {:error, :unexpected_network_lease} = VMManager.update("managed", resolved, manager)
    assert {:ok, ^before} = VMManager.Store.load(dir)
  end

  test "managed attachment admission requires a resolved lease" do
    request = Garden.VM.Network.request(socket_path: "/activator.sock")

    config = %VMManager.Config{
      id: "attached",
      kernel: "/kernel",
      mode: :attach,
      control_endpoint: "/api.sock",
      vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: "/guest.sock"},
      network: request
    }

    assert {:error, :missing_network_lease} = VMManager.Config.validate(config)

    assert :ok =
             VMManager.Config.validate(%{config | network: %{request | lease: "attached-lease"}})

    for mode <- [:launch, :attach] do
      assert :ok =
               VMManager.Config.validate(%{
                 config
                 | mode: mode,
                   vsock: if(mode == :attach, do: config.vsock, else: nil),
                   network: %VMManager.Network{
                     devices: [
                       %CloudHypervisor.Config.Net{tap: "caller", mac: "02:00:00:00:00:01"}
                     ]
                   }
               })
    end
  end

  defp write_manifest(dir, overrides) do
    manifest =
      Map.merge(
        %{
          "version" => 1,
          "system" => "x86_64-linux",
          "contract" => 1,
          "vsock_port" => 5000,
          "kernel" => "/nix/store/unavailable-image/kernel",
          "initrd" => "/nix/store/unavailable-image/initrd",
          "root" => "/nix/store/unavailable-image/root.erofs",
          "cmdline" => "console=ttyS0",
          "scratch" => %{
            "device" => "/dev/vdb",
            "label" => "sower-scratch",
            "filesystem" => "ext4"
          }
        },
        overrides
      )

    File.write!(Path.join(dir, "boot.json"), Jason.encode!(manifest))
  end
end
