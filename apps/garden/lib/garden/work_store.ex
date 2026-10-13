defmodule Garden.WorkStore do
  @moduledoc """
  Persistent isolated Nix store. A run reserves its maximum persistent output
  bytes at admission; input/cache representations and staging have independent
  limits. The backing directory must have capacity for the configured pools.
  External filesystem exhaustion is reported, never hidden by evicting live roots.

  Run roots and manifests survive service restart. Closing a run is idempotent,
  revokes/drains its executions, and only then releases its persistent roots.
  Native workers share root custody with the service. Uncertified worker death
  retains an on-disk barrier, preventing a replacement from mutating that root.
  """
  use GenServer
  use TypedStruct
  alias Garden.WorkStore.{Operations, Service, Transfer}

  typedstruct do
    field :data, Garden.WorkStore.Data.t(), enforce: true
    field :transfers, map(), default: %{}
    field :revoked, MapSet.t(), default: MapSet.new()
    field :closing, MapSet.t(), default: MapSet.new()
    field :busy, tuple()
    field :queue, :queue.queue(), default: :queue.new()
    field :drains, map(), default: %{}
    field :certificates, MapSet.t(), default: MapSet.new()
    field :revoked_owners, MapSet.t(), default: MapSet.new()
    field :failure, term()
  end

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, shutdown: 15_000}
  end

  def open_run(server, run_sid, input_roots, upstreams, output_budget),
    do: GenServer.call(server, {:open, run_sid, input_roots, upstreams, output_budget}, :infinity)

  def close_run(server, run_sid), do: GenServer.call(server, {:close_run, run_sid}, :infinity)
  def revoke_owner(server, owner), do: GenServer.call(server, {:revoke_owner, owner}, :infinity)
  def paths(server, run_sid), do: GenServer.call(server, {:paths, run_sid})
  def gc(server), do: GenServer.call(server, :gc, :infinity)

  def attach(server, run_sid, execution_id, directory, owner, deadline_ms),
    do:
      GenServer.call(
        server,
        {:attach, run_sid, execution_id, directory, owner, deadline_ms},
        :infinity
      )

  def detach(%Transfer{} = transfer) do
    try do
      Service.stop(transfer.service)
    catch
      :exit, {:noproc, _} ->
        certificate(transfer)

      :exit, reason ->
        case certificate(transfer) do
          :ok -> :ok
          {:error, _} -> {:error, {:transfer_cleanup, reason}}
        end
    end
  end

  def read(server, service, sid, key, mode) do
    operation = {if(mode == :write, do: :export, else: :read), sid, key}
    GenServer.call(server, {:request, service, operation}, :infinity)
  end

  def commit(server, service, sid, stage, key, token),
    do: GenServer.call(server, {:request, service, {:commit, sid, stage, key, token}}, :infinity)

  def revoke(server, service), do: GenServer.call(server, {:revoke, service}, :infinity)
  def certify(server, service), do: GenServer.call(server, {:certify, service})

  defp certificate(transfer) do
    try do
      GenServer.call(transfer.store, {:certificate, transfer.service})
    catch
      :exit, _ -> {:error, :transfer_cleanup_unconfirmed}
    end
  end

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)
    staging = Keyword.get(options, :staging_bytes, 2 * 1024 * 1024 * 1024)

    options =
      options
      |> Keyword.put_new(:nix, System.find_executable("nix"))
      |> Keyword.put_new(:output_bytes, 16 * 1024 * 1024 * 1024)
      |> Keyword.put_new(:cache_bytes, 4 * 1024 * 1024 * 1024)
      |> Keyword.put_new(:staging_bytes, staging)
      |> Keyword.put_new(:transfer_bytes, min(staging, 256 * 1024 * 1024))
      |> Keyword.put_new(:max_transfers, 8)

    if valid_options?(options) do
      options = Keyword.update!(options, :root, &Path.expand/1)

      options =
        Keyword.update!(options, :nix, fn executable ->
          System.find_executable(executable) || executable
        end)

      if :global.set_lock({{__MODULE__, options[:root]}, self()}, [node()], 0) do
        case Operations.load(options) do
          {:ok, data} ->
            {:ok, %__MODULE__{data: data}}

          {:error, reason} ->
            :global.del_lock({{__MODULE__, options[:root]}, self()}, [node()])
            {:stop, reason}
        end
      else
        {:stop, :work_store_already_owned}
      end
    else
      {:stop, :invalid_work_store_options}
    end
  end

  @impl GenServer
  def handle_call({:paths, sid}, _from, state) do
    case state.data.runs[sid] do
      nil -> {:reply, {:error, :run_closed}, state}
      run -> {:reply, {:ok, run.outputs}, state}
    end
  end

  def handle_call({:open, sid, _, _, _} = operation, from, state) do
    if MapSet.member?(state.closing, sid),
      do: {:reply, {:error, :run_closing}, state},
      else: enqueue(state, operation, from, nil)
  end

  def handle_call(:gc, from, state), do: enqueue(state, :gc, from, nil)

  def handle_call({:request, service, operation}, from, state) do
    if Map.has_key?(state.transfers, service) and not MapSet.member?(state.revoked, service) and
         not MapSet.member?(state.closing, elem(operation, 1)) do
      enqueue(state, operation, from, service)
    else
      {:reply, {:error, :revoked}, state}
    end
  end

  def handle_call({:certificate, service}, _from, state) do
    result =
      if MapSet.member?(state.certificates, service),
        do: :ok,
        else: {:error, :transfer_cleanup_unconfirmed}

    {:reply, result, state}
  end

  def handle_call({:certify, service}, _from, state) do
    {:reply, :ok,
     %{release(state, service) | certificates: MapSet.put(state.certificates, service)}}
  end

  def handle_call({:revoke, service}, from, state) do
    state = %{state | revoked: MapSet.put(state.revoked, service)}

    if state.failure do
      {:reply, {:error, {:cleanup_unconfirmed, state.failure}}, state}
    else
      if state.busy && elem(state.busy, 3) == service do
        send(elem(state.busy, 0), :cancel)
        {:noreply, %{state | drains: Map.update(state.drains, service, [from], &[from | &1])}}
      else
        {:reply, {:ok, get_in(state.transfers, [service, :paths]) || []}, state}
      end
    end
  end

  def handle_call({:attach, sid, id, directory, owner, deadline}, _from, state) do
    options = state.data.options

    cond do
      not Map.has_key?(state.data.runs, sid) or MapSet.member?(state.closing, sid) ->
        {:reply, {:error, :run_closed}, state}

      state.failure != nil ->
        {:reply, {:error, {:work_store_retained, state.failure}}, state}

      not is_pid(owner) or not is_integer(deadline) or deadline <= 0 or not is_binary(directory) ->
        {:reply, {:error, :invalid_transfer}, state}

      MapSet.member?(state.revoked_owners, owner) or not Process.alive?(owner) ->
        {:reply, {:error, :owner_revoked}, state}

      map_size(state.transfers) >= options[:max_transfers] or
          (map_size(state.transfers) + 1) * options[:transfer_bytes] +
            options[:retained_staging_bytes] > options[:staging_bytes] ->
        {:reply, {:error, :staging_capacity_exhausted}, state}

      true ->
        case Service.start(
               store: self(),
               sid: sid,
               execution_id: id,
               owner: owner,
               vmm_directory: directory,
               root: options[:root],
               limit: options[:transfer_bytes],
               deadline_ms: deadline
             ) do
          {:ok, service, transfer} ->
            Process.monitor(service)

            {:reply, {:ok, transfer},
             %{
               state
               | transfers:
                   Map.put(state.transfers, service, %{
                     sid: sid,
                     owner: owner,
                     execution_id: id,
                     paths: []
                   })
             }}

          {:error, reason, service, transfer} ->
            Process.monitor(service)
            spawn(fn -> detach(transfer) end)

            {:reply, {:error, {:transfer_start, reason}},
             %{
               state
               | transfers:
                   Map.put(state.transfers, service, %{
                     sid: sid,
                     owner: owner,
                     execution_id: id,
                     paths: []
                   })
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:revoke_owner, owner}, from, state) do
    services = for {service, %{owner: ^owner}} <- state.transfers, do: service
    parent = self()

    spawn(fn ->
      result =
        Enum.reduce_while(services, :ok, fn service, :ok ->
          case detach(%Transfer{service: service, store: parent, guest: %{}, sockets: []}) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      GenServer.reply(from, result)
    end)

    {:noreply, %{state | revoked_owners: MapSet.put(state.revoked_owners, owner)}}
  end

  def handle_call({:close_run, sid}, from, state) do
    services = for {service, %{sid: ^sid}} <- state.transfers, do: service
    parent = self()

    spawn(fn ->
      result =
        Enum.reduce_while(services, :ok, fn service, :ok ->
          case detach(%Transfer{service: service, store: parent, guest: %{}, sockets: []}) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      send(parent, {:close_drained, sid, from, result})
    end)

    {:noreply, %{state | closing: MapSet.put(state.closing, sid)}}
  end

  @impl GenServer
  def handle_info({:close_drained, sid, from, :ok}, state) do
    case enqueue(state, {:close, sid}, from, nil) do
      {:reply, error, state} ->
        GenServer.reply(from, error)
        {:noreply, state}

      result ->
        result
    end
  end

  def handle_info({:close_drained, _sid, from, error}, state) do
    GenServer.reply(from, error)
    {:noreply, state}
  end

  def handle_info(
        {:operation_done, pid, result, data},
        %{busy: {pid, monitor, from, service, operation}} = state
      ) do
    if service && match?({:commit, _, _, _, _}, operation),
      do: Service.unlock(service, elem(operation, 4))

    Process.demonitor(monitor, [:flush])

    {committed, result} =
      case {operation, result} do
        {{:commit, _, _, _, _}, {:ok, paths}} ->
          {paths, result}

        {{:export, _, _}, {:ok, bytes, url, filename, paths}} ->
          {paths, {:ok, bytes, url, filename}}

        _ ->
          {[], result}
      end

    state =
      if committed != [] do
        case state.transfers[service] do
          %{owner: owner, execution_id: id} = transfer ->
            paths = Enum.sort(Enum.uniq(transfer.paths ++ committed))
            if paths != transfer.paths, do: send(owner, {:work_store_paths, id, paths})
            put_in(state.transfers[service].paths, paths)

          _ ->
            state
        end
      else
        state
      end

    GenServer.reply(from, result)

    dirty =
      match?({:error, _}, result) and
        (operation == :gc or elem(operation, 0) in [:open, :commit, :close, :export])

    data = %{data | dirty: data.dirty or dirty}
    state = %{state | busy: nil, data: data}

    state =
      case operation do
        {:close, sid} when result == :ok -> %{state | closing: MapSet.delete(state.closing, sid)}
        _ -> state
      end

    cleanup =
      case result do
        {:error, {:cleanup_unconfirmed, _}} = failure -> failure
        _ -> {:ok, get_in(state.transfers, [service, :paths]) || []}
      end

    Enum.each(Map.get(state.drains, service, []), &GenServer.reply(&1, cleanup))

    state = %{
      state
      | drains: Map.delete(state.drains, service),
        failure:
          if(match?({:error, {:cleanup_unconfirmed, _}}, result), do: result, else: state.failure)
    }

    {:noreply, next(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{busy: {pid, monitor, from, service, _}} = state
      ) do
    GenServer.reply(from, {:error, {:operation_down, reason}})

    Enum.each(
      Map.get(state.drains, service, []),
      &GenServer.reply(&1, {:error, :operation_cleanup_unconfirmed})
    )

    {:noreply, next(%{state | busy: nil, failure: {:operation_cleanup_unconfirmed, reason}})}
  end

  def handle_info({:DOWN, _monitor, :process, service, _reason}, state) do
    if Map.has_key?(state.transfers, service) do
      # A service normally unregisters only after its teardown certificate.
      if state.busy && elem(state.busy, 3) == service, do: send(elem(state.busy, 0), :cancel)
      {:noreply, %{state | revoked: MapSet.put(state.revoked, service)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.busy do
      {pid, monitor, _, _, _} = state.busy
      send(pid, :cancel)

      receive do
        {:operation_done, ^pid, _, _} -> :ok
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        10_000 -> :ok
      end
    end

    :global.del_lock({{__MODULE__, state.data.options[:root]}, self()}, [node()])
    :ok
  end

  defp enqueue(state, operation, from, service) do
    if :queue.len(state.queue) >= 64 do
      {:reply, {:error, :work_store_busy}, state}
    else
      {:noreply, next(%{state | queue: :queue.in({operation, from, service}, state.queue)})}
    end
  end

  defp next(%{busy: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {operation, from, service}}, queue} ->
        if state.failure do
          GenServer.reply(from, {:error, {:work_store_retained, state.failure}})
          next(%{state | queue: queue})
        else
          state = %{state | queue: queue}

          if service && MapSet.member?(state.revoked, service) do
            GenServer.reply(from, {:error, :revoked})
            next(state)
          else
            parent = self()
            data = state.data

            {pid, monitor} =
              spawn_monitor(fn ->
                Process.flag(:trap_exit, true)
                Process.monitor(parent)
                Process.monitor(elem(from, 0))

                # Keep root custody through native cleanup even if the service is killed.
                lock = {{__MODULE__, data.options[:root]}, parent}

                if :global.set_lock(lock, [node()], 0) do
                  {result, data} = run_operation(data, operation)
                  send(parent, {:operation_done, self(), result, data})
                  :global.del_lock(lock, [node()])
                else
                  send(
                    parent,
                    {:operation_done, self(), {:error, :work_store_already_owned}, data}
                  )
                end
              end)

            %{state | busy: {pid, monitor, from, service, operation}}
          end
        end

      {:empty, _} ->
        state
    end
  end

  defp next(state), do: state

  defp run_operation(%Garden.WorkStore.Data{} = data, operation) do
    pending = Path.join(data.options[:root], "operation.pending")

    case File.write(pending, "native work is not certified\n", [:sync]) do
      :ok ->
        {prepared, data} =
          if data.dirty, do: Operations.perform(data, :refresh), else: {:ok, data}

        {result, data} =
          if prepared == :ok,
            do: Operations.perform(data, operation),
            else: {prepared, data}

        case result do
          {:error, {:cleanup_unconfirmed, _}} ->
            {result, data}

          _ ->
            case File.rm(pending) do
              :ok -> {result, data}
              {:error, reason} -> {{:error, {:cleanup_unconfirmed, reason}}, data}
            end
        end

      {:error, reason} ->
        {{:error, {:cleanup_unconfirmed, reason}}, data}
    end
  end

  defp release(state, service),
    do: %{
      state
      | transfers: Map.delete(state.transfers, service),
        drains: Map.delete(state.drains, service)
    }

  defp valid_options?(options) do
    is_binary(options[:root]) and Path.type(options[:root]) == :absolute and options[:root] != "/" and
      is_binary(options[:nix]) and is_binary(System.find_executable("sh")) and
      Enum.all?(
        [:output_bytes, :cache_bytes, :staging_bytes, :transfer_bytes, :max_transfers],
        &(is_integer(options[&1]) and options[&1] > 0)
      ) and options[:transfer_bytes] <= options[:staging_bytes]
  end
end
