defmodule VMManager.NetworkAllocationTest do
  use ExUnit.Case, async: true

  alias VMManager.{Config, Network}

  defmodule Leases do
    def provision(allocation_id, options) do
      path = Path.join(options[:directory], allocation_id)

      case File.write(path, "active", [:exclusive]) do
        :ok -> File.write!(options[:journal], allocation_id <> "\n", [:append])
        {:error, :eexist} -> :ok
      end

      if socket_path = options[:gate] do
        {:ok, socket} =
          :gen_tcp.connect({:local, String.to_charlist(socket_path)}, 0, [
            :binary,
            active: false,
            packet: :line
          ])

        :ok = :gen_tcp.send(socket, allocation_id <> "\n")
        {:ok, "continue\n"} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.close(socket)
      end

      {:ok,
       %Network{
         ownership: :managed,
         provider: __MODULE__,
         options: options,
         lease: allocation_id
       }}
    end

    def revoke(lease, options), do: File.write(Path.join(options[:directory], lease), "revoked")
    def release(lease, options), do: File.rm(Path.join(options[:directory], lease))
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "network-allocation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    config = %Config{
      id: "shared-vm",
      network: %Network{
        ownership: :managed,
        provider: Leases,
        options: [directory: directory, journal: Path.join(directory, "journal")]
      }
    }

    %{config: config, directory: directory}
  end

  test "real managers namespace equal VM IDs and each new attempt owns a fresh lease", context do
    gate = Path.join(System.tmp_dir!(), "allocation-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, gate}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm!(gate)
    end)

    network = %{context.config.network | options: context.config.network.options ++ [gate: gate]}
    config = %{context.config | kernel: "/kernel", network: network}

    managers =
      for name <- [:first, :second] do
        runtime =
          start_supervised!(
            Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one},
              id: {name, :runtime}
            )
          )

        manager =
          start_supervised!(
            Supervisor.child_spec(
              {VMManager.Manager,
               state_directory: Path.join(context.directory, Atom.to_string(name)),
               runtime_supervisor: runtime},
              id: {name, :manager}
            )
          )

        assert {:ok, "shared-vm"} = VMManager.define(config, manager)
        manager
      end

    [first, second] = managers
    assert :ok = VMManager.start(config.id, first)
    {first_socket, first_id} = allocation(listener)
    assert :ok = VMManager.start(config.id, second)
    {second_socket, second_id} = allocation(listener)
    refute first_id == second_id

    stop_allocating(first, config.id, first_socket)
    refute File.exists?(Path.join(context.directory, first_id))
    assert File.read!(Path.join(context.directory, second_id)) == "active"
    stop_allocating(second, config.id, second_socket)

    assert :ok = VMManager.start(config.id, first)
    {next_socket, next_id} = allocation(listener)
    refute next_id in [first_id, second_id]
    stop_allocating(first, config.id, next_socket)

    assert length(
             String.split(File.read!(Path.join(context.directory, "journal")), "\n", trim: true)
           ) == 3
  end

  defp allocation(listener) do
    assert {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    assert {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    {socket, String.trim_trailing(line, "\n")}
  end

  defp stop_allocating(manager, id, socket) do
    request = :gen_server.send_request(manager, {:stop, id})
    assert {:ok, %{desired: :stopped}} = VMManager.status(id, manager)
    assert :ok = :gen_tcp.send(socket, "continue\n")
    assert :ok = :gen_tcp.close(socket)
    assert {:reply, :ok} = :gen_server.receive_response(request, 5_000)
  end

  test "independent allocations of the same VM retain separate lease custody", context do
    assert {:ok, first} = Network.provision(context.config, "manager-a-attempt-1")
    assert {:ok, second} = Network.provision(context.config, "manager-b-attempt-1")
    refute first.lease == second.lease

    assert :ok = Network.revoke(first)
    assert :ok = Network.release(first)
    assert File.read!(Path.join(context.directory, second.lease)) == "active"

    assert {:ok, next} = Network.provision(context.config, "manager-a-attempt-2")
    refute next.lease in [first.lease, second.lease]
    refute File.exists?(Path.join(context.directory, first.lease))
  end

  test "retry and restored custody do not allocate a second lease", context do
    assert {:ok, first} = Network.provision(context.config, "manager-a-attempt-1")
    assert {:ok, ^first} = Network.provision(context.config, "manager-a-attempt-1")
    restored = %{context.config | network: first}
    assert {:ok, ^first} = Network.provision(restored, "manager-a-attempt-1")
    assert File.read!(Path.join(context.directory, "journal")) == "manager-a-attempt-1\n"
  end

  test "allocation identities are nonempty bounded binaries", context do
    for invalid <- [nil, :shared, "", String.duplicate("a", 129)] do
      assert {:error, :invalid_network_allocation_id} = Network.provision(context.config, invalid)
    end

    refute File.exists?(Path.join(context.directory, "journal"))
  end
end
