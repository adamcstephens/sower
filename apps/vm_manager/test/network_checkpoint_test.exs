defmodule VMManager.NetworkCheckpointTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Manager, Network, Store}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "network-checkpoint-#{System.unique_integer([:positive])}")

    config = %Config{id: "checkpoint", kernel: "/kernel"}

    definition = %Manager.Definition{
      config: config,
      reserved: true,
      attempt: "current",
      boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim()
    }

    :ok = Store.save(directory, %{config.id => definition})
    {:ok, manager} = Manager.start_link(state_directory: directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, config: config, manager: manager}
  end

  test "only the current reserved attempt checkpoints its resolved network without changing the request",
       context do
    lease = %Network{
      ownership: :external,
      devices: [%CloudHypervisor.Config.Net{tap: "tap0", mac: "02:00:00:00:00:01"}]
    }

    assert {:error, :stale_attempt} =
             GenServer.call(
               context.manager,
               {:checkpoint_network, context.config.id, "stale", lease}
             )

    assert :ok =
             GenServer.call(
               context.manager,
               {:checkpoint_network, context.config.id, "current", lease}
             )

    assert {:ok, definitions} = Store.load(context.directory)
    assert definitions[context.config.id].network == lease
    assert definitions[context.config.id].config.network == nil
    GenServer.stop(context.manager)
  end

  test "failed durable checkpoint does not accept an in-memory lease", context do
    path = Path.join(context.directory, "definitions.etf")
    File.rm!(path)
    File.mkdir!(path)
    lease = %Network{}

    assert {:error, {:durable_store, _}} =
             GenServer.call(
               context.manager,
               {:checkpoint_network, context.config.id, "current", lease}
             )

    File.rmdir!(path)

    assert :ok =
             GenServer.call(
               context.manager,
               {:checkpoint_network, context.config.id, "current", nil}
             )

    assert {:ok, definitions} = Store.load(context.directory)
    assert definitions[context.config.id].network == nil
    GenServer.stop(context.manager)
  end
end
