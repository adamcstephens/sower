defmodule Garden.ImageTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "rejects an unsupported executor contract before resolving boot artifacts", %{tmp_dir: dir} do
    write_manifest(dir, %{"contract" => 3})

    assert {:error, {:unsupported_contract, 3}} = Garden.Image.load(dir)
  end

  test "rejects an unsupported architecture before resolving boot artifacts", %{tmp_dir: dir} do
    write_manifest(dir, %{"system" => "aarch64-linux"})

    assert {:error, {:unsupported_system, "aarch64-linux"}} = Garden.Image.load(dir)
  end

  test "command-only images remain supported", %{tmp_dir: dir} do
    write_manifest(dir, %{})

    assert {:error, {:invalid_boot_artifact, "kernel"}} = Garden.Image.load(dir)
  end

  test "work-store contract requires the fixed transport ports", %{tmp_dir: dir} do
    write_manifest(dir, %{
      "contract" => 2,
      "work_store_read_port" => 5001,
      "work_store_write_port" => 5002
    })

    assert {:error, {:invalid_boot_artifact, "kernel"}} = Garden.Image.load(dir)

    write_manifest(dir, %{
      "contract" => 2,
      "work_store_read_port" => 6001,
      "work_store_write_port" => 5002
    })

    assert {:error, :invalid_boot_metadata} = Garden.Image.load(dir)
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
