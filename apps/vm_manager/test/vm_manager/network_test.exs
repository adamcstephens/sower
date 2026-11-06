defmodule VMManager.NetworkTest do
  use ExUnit.Case, async: true

  alias VMManager.{Config, Network}

  test "admission rejects malformed attachments and ambiguous custody" do
    assert Network.valid?(nil)
    assert Network.valid?(%Network{})
    refute Network.valid?(:full)
    refute Network.valid?(%Network{devices: ["tap0"]})
    refute Network.valid?(%Network{cmdline: nil})
    refute Network.valid?(%Network{lease: "not-external"})
    refute Network.valid?(%Network{provider: __MODULE__})
    refute Network.valid?(%Network{ownership: :managed})
    refute Network.valid?(%Network{ownership: :managed, provider: __MODULE__})
    refute Network.valid?(%Network{options: [process: self()]})
    refute Network.valid?(%Network{options: [callback: fn -> :ok end]})
  end

  @tag :tmp_dir
  test "configuration and network admission share recursive durable-container semantics",
       %{tmp_dir: directory} do
    options = %{
      nested: {%CloudHypervisor.Config.Net{tap: "caller", mac: "02:00:00:00:00:03"}, [1 | "tail"]}
    }

    network = %Network{options: options}
    config = %Config{id: "containers", kernel: "/kernel", network: network}

    assert Network.valid?(network)
    assert :ok = Config.validate(config)

    persisted = %{"config" => config, "options" => options}
    assert :ok = VMManager.Store.save(directory, persisted)
    assert {:ok, ^persisted} = VMManager.Store.load(directory)

    for live <- [self(), make_ref(), fn -> :ok end] do
      network = %{network | options: %{nested: {[1 | live], options}}}
      refute Network.valid?(network)
      assert {:error, {:invalid_option, :network}} = Config.validate(%{config | network: network})

      assert {:error, :non_serializable_configuration} =
               Config.validate(%{config | runtime_directory: %{nested: {[1 | live], options}}})
    end
  end

  test "no network provisions no devices and requires no cleanup" do
    assert {:ok, nil} = Network.provision(%Config{id: "isolated"}, "allocation-isolated")
    assert Network.devices(nil) == []
    assert Network.cmdline(nil) == ""
    assert :ok = Network.revoke(nil)
    assert :ok = Network.release(nil)
  end

  test "external native devices retain ordering and caller custody" do
    devices = [
      %CloudHypervisor.Config.Net{tap: "caller-a", mac: "02:00:00:00:00:01"},
      %CloudHypervisor.Config.Net{tap: "caller-b", mac: "02:00:00:00:00:02"}
    ]

    network = %Network{ownership: :external, devices: devices, cmdline: " ip=dhcp"}

    assert {:ok, ^network} =
             Network.provision(%Config{id: "external", network: network}, "allocation-external")

    assert Network.devices(network) == devices
    assert Network.cmdline(network) == " ip=dhcp"
    assert :ok = Network.revoke(network)
    assert :ok = Network.release(network)
  end

  test "resolved managed attachments are not provisioned again" do
    network = %Network{ownership: :managed, lease: "durable-lease"}

    assert {:ok, ^network} =
             Network.provision(%Config{id: "restored", network: network}, "allocation-restored")
  end

  test "unresolved managed requests have no lease to revoke or release" do
    network = %Network{ownership: :managed}

    assert :ok = Network.revoke(network)
    assert :ok = Network.release(network)
  end
end
