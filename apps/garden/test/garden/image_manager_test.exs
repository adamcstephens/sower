defmodule Garden.Image.ManagerTest do
  use ExUnit.Case, async: false
  alias Garden.Image
  alias Garden.Image.Manager

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    token = make_ref()

    names = %{
      supervisor: {:global, {token, :supervisor}},
      manager: {:global, {token, :manager}},
      executions: {:global, {token, :executions}},
      ledger: {:global, {token, :ledger}}
    }

    formatter = Path.join(directory, "formatter")

    File.write!(
      formatter,
      "#!/usr/bin/env sh\nfor scratch do :; done\nprintf ready > \"$scratch.ready\"\nexec sleep 60\n"
    )

    File.chmod!(formatter, 0o700)

    image = %Image{
      directory: directory,
      kernel: "/unavailable/kernel",
      initrd: "/unavailable/initrd",
      root: "/unavailable/root",
      cmdline: ""
    }

    options = [
      image: image,
      command: %Image.Command{path: "/bin/true"},
      owner: self(),
      mkfs: formatter,
      resource_directory: directory,
      cpus: 1,
      memory: 1,
      scratch_bytes: 4096,
      deadline_ms: 60_000
    ]

    supervisor_options = [
      name: names.supervisor,
      manager: names.manager,
      execution_supervisor: names.executions,
      ledger: names.ledger,
      budgets: [vms: 2, cpus: 2, memory: 2, scratch_bytes: 8192],
      shutdown_ms: 1000
    ]

    {:ok, supervisor} = Image.Supervisor.start_link(supervisor_options)
    Process.unlink(supervisor)

    on_exit(fn ->
      case GenServer.whereis(names.supervisor) do
        nil -> :ok
        pid -> Supervisor.stop(pid, :normal, :infinity)
      end
    end)

    {:ok,
     names: names,
     supervisor: supervisor,
     supervisor_options: supervisor_options,
     options: options}
  end

  test "atomic concurrent admission distinguishes oversized and exhausted requests", context do
    assert {:error, {:request_exceeds_capacity, :cpus}} =
             Manager.start(Keyword.put(context.options, :cpus, 3), context.names.manager)

    assert {:ok, []} = File.ls(context.options[:resource_directory]) |> without_formatter()

    results =
      1..12
      |> Enum.map(fn _ ->
        Task.async(fn -> Manager.start(context.options, context.names.manager) end)
      end)
      |> Enum.map(&Task.await/1)

    admitted = for {:ok, id} <- results, do: id
    assert length(admitted) == 2
    assert Enum.count(results, &(&1 == {:error, {:capacity_exhausted, :vms}})) == 10

    Enum.each(admitted, fn id ->
      status = ready(id, context.names.manager)
      File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
      assert :ok = Manager.cancel(id, context.names.manager)
      assert {:error, :cancelled} = Manager.await(id, context.names.manager)

      assert {:ok, %Image.Status{phase: :finished, cleanup: :ok}} =
               Manager.status(id, context.names.manager)

      eventually(fn -> not Process.alive?(status.execution) end)
    end)

    assert {:ok, fresh} = Manager.start(context.options, context.names.manager)
    cancel_clean(fresh, context.names.manager)
  end

  test "each admission dimension is held until cleanup certification", context do
    {:ok, id} =
      Manager.start(
        Keyword.merge(context.options, cpus: 2, memory: 2, scratch_bytes: 8192),
        context.names.manager
      )

    status = ready(id, context.names.manager)

    for {dimension, value} <- [cpus: 3, memory: 3, scratch_bytes: 8193] do
      assert {:error, {:request_exceeds_capacity, ^dimension}} =
               Manager.start(
                 Keyword.put(context.options, dimension, value),
                 context.names.manager
               )
    end

    assert {:error, {:capacity_exhausted, :cpus}} =
             Manager.start(context.options, context.names.manager)

    File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
    assert :ok = Manager.cancel(id, context.names.manager)
    assert {:error, :cancelled} = Manager.await(id, context.names.manager)
    {:ok, next} = Manager.start(context.options, context.names.manager)
    cancel_clean(next, context.names.manager)
  end

  test "unexpected files retain failures and reservations across whole subtree replacement",
       context do
    {:ok, id} = Manager.start(Keyword.put(context.options, :cpus, 2), context.names.manager)
    status = ready(id, context.names.manager)
    assert :ok = Manager.cancel(id, context.names.manager)

    assert {:error,
            {:cleanup_unconfirmed, {:error, :cancelled}, {:error, {:unexpected_files, _}},
             directory}} = Manager.await(id, context.names.manager)

    assert directory == status.directory
    assert File.exists?(Path.join(directory, "scratch.ext4.ready"))

    assert {:error, {:capacity_exhausted, :cpus}} =
             Manager.start(context.options, context.names.manager)

    Supervisor.stop(context.supervisor)
    {:ok, replacement} = Image.Supervisor.start_link(context.supervisor_options)
    Process.unlink(replacement)

    assert {:ok, %Image.Status{phase: :retained, directory: ^directory}} =
             Manager.status(id, context.names.manager)

    assert {:error, {:capacity_exhausted, :cpus}} =
             Manager.start(context.options, context.names.manager)

    assert {:error, {:cleanup_incomplete, [{^id, _, ^directory}]}} =
             Manager.shutdown(context.names.manager)

    assert {:error, :draining} = Manager.start(context.options, context.names.manager)
  end

  test "bounded clean retention never evicts failed cleanup", context do
    Supervisor.stop(context.supervisor)

    {:ok, supervisor} =
      Image.Supervisor.start_link(Keyword.put(context.supervisor_options, :result_limit, 1))

    Process.unlink(supervisor)
    {:ok, retained} = Manager.start(context.options, context.names.manager)
    ready(retained, context.names.manager)
    Manager.cancel(retained, context.names.manager)

    assert {:error, {:cleanup_unconfirmed, _, _, _}} =
             Manager.await(retained, context.names.manager)

    {:ok, first} = Manager.start(context.options, context.names.manager)
    cancel_clean(first, context.names.manager)
    {:ok, second} = Manager.start(context.options, context.names.manager)
    cancel_clean(second, context.names.manager)
    assert {:error, :not_found} = Manager.status(first, context.names.manager)
    assert {:ok, %Image.Status{phase: :finished}} = Manager.status(second, context.names.manager)

    assert {:ok, %Image.Status{phase: :retained}} =
             Manager.status(retained, context.names.manager)

    assert :ok = Manager.cancel(retained, context.names.manager)

    assert {:ok, %Image.Status{phase: :retained}} =
             Manager.status(retained, context.names.manager)
  end

  test "manager and execution supervisor recovery drain before reopening", context do
    for target <- [context.names.manager, context.names.executions, context.names.ledger] do
      {:ok, id} = Manager.start(context.options, context.names.manager)
      status = ready(id, context.names.manager)
      File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
      suspend_guard(status.guard)
      old = GenServer.whereis(target)
      Process.exit(old, :kill)
      eventually(fn -> GenServer.whereis(target) not in [nil, old] end)
      assert {:error, :draining} = Manager.start(context.options, context.names.manager)
      :erlang.resume_process(status.guard)
      assert {:error, :owner_down} = Manager.await(id, context.names.manager)

      eventually(fn ->
        match?({:ok, %Image.Status{phase: :finished}}, Manager.status(id, context.names.manager))
      end)

      refute File.exists?(status.directory)
    end
  end

  test "memory and scratch exhaustion reject without consuming remaining VM slots", context do
    for {dimension, value} <- [memory: 2, scratch_bytes: 8192] do
      {:ok, id} =
        Manager.start(Keyword.put(context.options, dimension, value), context.names.manager)

      ready(id, context.names.manager)

      assert {:error, {:capacity_exhausted, ^dimension}} =
               Manager.start(context.options, context.names.manager)

      cancel_clean(id, context.names.manager)
    end
  end

  test "guard death cannot certify teardown or release its reservation", context do
    {:ok, id} = Manager.start(Keyword.put(context.options, :cpus, 2), context.names.manager)
    status = ready(id, context.names.manager)
    Process.exit(status.guard, :kill)

    assert {:error,
            {:cleanup_unconfirmed, {:error, {:guard_down, :killed}}, :unconfirmed, directory}} =
             Manager.await(id, context.names.manager)

    assert directory == status.directory

    assert {:ok, %Image.Status{phase: :retained, cleanup: :unconfirmed}} =
             Manager.status(id, context.names.manager)

    assert {:error, {:capacity_exhausted, :cpus}} =
             Manager.start(context.options, context.names.manager)
  end

  test "execution deadline stops a real formatter and certifies owned file removal", context do
    {:ok, id} =
      Manager.start(Keyword.put(context.options, :deadline_ms, 2000), context.names.manager)

    status = ready(id, context.names.manager)
    File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
    assert {:error, :timeout} = Manager.await(id, context.names.manager)
    refute File.exists?(status.directory)

    assert {:ok, %Image.Status{phase: :finished, cleanup: :ok}} =
             Manager.status(id, context.names.manager)
  end

  test "whole subtree death restores accounting and certifies old guards without replay",
       context do
    {:ok, id} = Manager.start(context.options, context.names.manager)
    status = ready(id, context.names.manager)
    File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
    suspend_guard(status.guard)
    Process.exit(context.supervisor, :kill)

    eventually(fn ->
      Enum.all?(
        [
          context.names.supervisor,
          context.names.manager,
          context.names.executions,
          context.names.ledger
        ],
        &(GenServer.whereis(&1) == nil)
      )
    end)

    {:ok, replacement} = Image.Supervisor.start_link(context.supervisor_options)
    Process.unlink(replacement)
    assert {:error, :draining} = Manager.start(context.options, context.names.manager)
    :erlang.resume_process(status.guard)
    assert {:error, :owner_down} = Manager.await(id, context.names.manager)
    refute File.exists?(status.directory)
    {:ok, fresh} = Manager.start(context.options, context.names.manager)
    assert fresh != id
    cancel_clean(fresh, context.names.manager)
  end

  test "controller death and explicit owner death use independent guard teardown", context do
    for target <- [:execution, :owner] do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, id} =
        Manager.start(Keyword.put(context.options, :owner, owner), context.names.manager)

      status = ready(id, context.names.manager)
      assert status.owner == owner
      File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
      Process.exit(Map.fetch!(status, target), :kill)
      assert {:error, :owner_down} = Manager.await(id, context.names.manager)
      refute File.exists?(status.directory)
      Process.exit(owner, :kill)
    end
  end

  test "shutdown deadline reports incomplete cleanup and actual supervisor stop drains",
       context do
    {:ok, id} = Manager.start(context.options, context.names.manager)
    status = ready(id, context.names.manager)
    File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
    suspend_guard(status.guard)
    shutdown = Task.async(fn -> Manager.shutdown(context.names.manager) end)

    eventually(fn ->
      Manager.start(Keyword.put(context.options, :cpus, 3), context.names.manager) ==
        {:error, :draining}
    end)

    assert {:error, {:cleanup_incomplete, [{^id, :pending, _}]}} = Task.await(shutdown)

    assert {:ok, %Image.Status{phase: :starting, cleanup: nil}} =
             Manager.status(id, context.names.manager)

    :erlang.resume_process(status.guard)
    assert {:error, :cancelled} = Manager.await(id, context.names.manager)
    assert :ok = Manager.shutdown(context.names.manager)
    Supervisor.stop(context.supervisor)
    {:ok, replacement} = Image.Supervisor.start_link(context.supervisor_options)
    Process.unlink(replacement)
    {:ok, next} = Manager.start(context.options, context.names.manager)
    next_status = ready(next, context.names.manager)
    File.rm!(Path.join(next_status.directory, "scratch.ext4.ready"))
    Supervisor.stop(replacement)
    refute File.exists?(next_status.directory)
    refute Process.alive?(next_status.guard)
  end

  defp ready(id, manager) do
    eventually(fn ->
      case Manager.status(id, manager) do
        {:ok, %Image.Status{directory: directory}} when is_binary(directory) ->
          File.exists?(Path.join(directory, "scratch.ext4.ready"))

        _ ->
          false
      end
    end)

    {:ok, status} = Manager.status(id, manager)
    status
  end

  defp cancel_clean(id, manager) do
    status = ready(id, manager)
    File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
    assert :ok = Manager.cancel(id, manager)
    assert {:error, :cancelled} = Manager.await(id, manager)
  end

  defp without_formatter({:ok, files}), do: {:ok, files -- ["formatter"]}

  defp suspend_guard(guard) do
    :erlang.suspend_process(guard)

    on_exit(fn ->
      case Process.info(guard, :status) do
        {:status, :suspended} -> :erlang.resume_process(guard)
        _ -> :ok
      end
    end)
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 5000)

  defp eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      eventually(fun, deadline)
    end
  end
end
