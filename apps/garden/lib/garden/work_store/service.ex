defmodule Garden.WorkStore.Service do
  @moduledoc false
  use GenServer
  use TypedStruct
  alias Garden.WorkStore.Transfer

  typedstruct do
    field :store, pid(), enforce: true
    field :sid, String.t(), enforce: true
    field :execution_id, term(), enforce: true
    field :owner, pid(), enforce: true
    field :directory, String.t(), enforce: true
    field :limit, pos_integer(), enforce: true
    field :listeners, [pid()], default: []
    field :sockets, [String.t()], default: []
    field :uploads, map(), default: %{}
    field :objects, map(), default: %{}
    field :authorized_nars, map(), default: %{}
    field :used, non_neg_integer(), default: 0
    field :overhead, non_neg_integer(), default: 65_536
    field :revoked, boolean(), default: false
    field :startup_error, term()
    field :validating, reference()
    field :waiters, list(), default: []
  end

  def start(options) do
    reference = make_ref()

    case GenServer.start(__MODULE__, Keyword.put(options, :startup_reference, reference)) do
      {:ok, service} ->
        receive do
          {^reference, :ok, transfer} -> {:ok, service, transfer}
          {^reference, {:error, reason}, transfer} -> {:error, reason, service, transfer}
        end

      error ->
        error
    end
  end

  def stop(service), do: GenServer.call(service, :stop, :infinity)
  def context(service), do: GenServer.call(service, :context)

  def begin_upload(service, key, size),
    do: GenServer.call(service, {:begin, key, size}, :infinity)

  def finish_upload(service, token, size, digest),
    do: GenServer.call(service, {:finish, token, size, digest})

  def abandon(service, token), do: GenServer.call(service, {:abandon, token})
  def authorize(service, url, filename), do: GenServer.call(service, {:authorize, url, filename})
  def lookup(service, url), do: GenServer.call(service, {:lookup, url})
  def lock(service), do: GenServer.call(service, :lock, :infinity)
  def unlock(service, token), do: GenServer.cast(service, {:unlock, token})

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)
    store = Keyword.fetch!(options, :store)
    owner = Keyword.fetch!(options, :owner)
    Process.monitor(store)
    Process.monitor(owner)

    sockets =
      Enum.map([5001, 5002], &(Path.join(options[:vmm_directory], "vsock.sock") <> "_#{&1}"))

    directory =
      Path.join([
        options[:root],
        "staging",
        Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      ])

    state = %__MODULE__{
      store: store,
      owner: owner,
      sid: options[:sid],
      execution_id: options[:execution_id],
      directory: directory,
      limit: options[:limit]
    }

    prepared =
      with :ok <- File.mkdir(directory),
           :ok <- File.chmod(directory, 0o700),
           :ok <- File.mkdir(Path.join(directory, "nar")),
           :ok <-
             File.write(
               Path.join(directory, "nix-cache-info"),
               "StoreDir: /nix/store\nWantMassQuery: 0\nPriority: 30\n"
             ) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    {result, state} =
      if prepared == :ok,
        do: start_listeners(state, Enum.zip([:read, :write], sockets)),
        else: {prepared, state}

    transfer = %Transfer{
      service: self(),
      store: store,
      sockets: state.sockets,
      guest: %{
        read_url: "http://127.0.0.1:5001?trusted=true",
        write_url: "http://127.0.0.1:5002?trusted=true"
      }
    }

    send(store, {options[:startup_reference], result, transfer})

    if result == :ok do
      Process.send_after(self(), :deadline, options[:deadline_ms])
      {:ok, state}
    else
      {:ok, %{state | revoked: true, startup_error: elem(result, 1)}}
    end
  end

  defp start_listeners(state, []), do: {:ok, state}

  defp start_listeners(state, [{mode, socket} | rest]) do
    case File.lstat(socket) do
      {:error, :enoent} ->
        case listener(self(), mode, socket) do
          {:ok, pid} ->
            start_listeners(
              %{state | listeners: state.listeners ++ [pid], sockets: state.sockets ++ [socket]},
              rest
            )

          {:error, reason} ->
            {{:error, reason}, state}
        end

      _ ->
        {{:error, :existing_transfer_socket}, state}
    end
  end

  defp listener(service, mode, socket) do
    Bandit.start_link(
      plug: {Garden.WorkStore.HTTP, {service, mode}},
      ip: {:local, socket},
      port: 0,
      startup_log: false,
      http_options: [compress: false, log_protocol_errors: false, log_client_closures: false],
      http_2_options: [enabled: false],
      thousand_island_options: [
        num_acceptors: 2,
        num_connections: 4,
        read_timeout: 10_000,
        shutdown_timeout: 1000
      ]
    )
  end

  @impl GenServer
  def handle_call(:context, _from, %{revoked: false} = state),
    do: {:reply, {:ok, state.store, state.sid, state.directory, state.limit}, state}

  def handle_call(:context, _from, state), do: {:reply, {:error, :revoked}, state}

  def handle_call(:lock, from, state) do
    cond do
      state.revoked ->
        {:reply, {:error, :revoked}, state}

      state.validating != nil or map_size(state.uploads) != 0 ->
        queue_request(state, :lock, from)

      true ->
        token = make_ref()
        {:reply, {:ok, token}, %{state | validating: token}}
    end
  end

  def handle_call({:begin, key, size} = request, {pid, _} = from, %{revoked: false} = state) do
    cond do
      state.validating != nil or map_size(state.uploads) >= 8 ->
        queue_request(state, request, from)

      not is_integer(size) or size < 0 or size + state.used + state.overhead > state.limit ->
        {:reply, {:error, :staging_budget_exceeded}, state}

      Enum.any?(state.uploads, fn {_, upload} -> upload.key == key end) ->
        queue_request(state, request, from)

      true ->
        token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        filename = Path.join(state.directory, token <> ".upload")
        monitor = Process.monitor(pid)
        upload = %{key: key, size: size, filename: filename, monitor: monitor}

        {:reply, {:ok, token, filename},
         %{state | used: state.used + size, uploads: Map.put(state.uploads, token, upload)}}
    end
  end

  def handle_call({:begin, _, _}, _from, state), do: {:reply, {:error, :revoked}, state}

  def handle_call({:finish, token, size, digest}, _from, state) do
    send(self(), :wake_waiters)

    case Map.fetch(state.uploads, token) do
      {:ok, upload} when size <= upload.size and not state.revoked ->
        destination = Path.join(state.directory, upload.key)

        result =
          if File.regular?(destination) do
            if state.objects[upload.key] == %{size: size, digest: digest},
              do: File.rm(upload.filename),
              else: {:error, :upload_conflict}
          else
            File.rename(upload.filename, destination)
          end

        Process.demonitor(upload.monitor, [:flush])

        if result == :ok do
          duplicate = Map.has_key?(state.objects, upload.key)

          state = %{
            state
            | uploads: Map.delete(state.uploads, token),
              objects: Map.put(state.objects, upload.key, %{size: size, digest: digest}),
              used: state.used - upload.size + if(duplicate, do: 0, else: size)
          }

          {:reply, :ok, state}
        else
          {:reply, result, discard(state, token)}
        end

      _ ->
        {:reply, {:error, :incomplete_upload}, discard(state, token)}
    end
  end

  def handle_call({:abandon, token}, _from, state) do
    send(self(), :wake_waiters)
    {:reply, :ok, discard(state, token)}
  end

  def handle_call({:authorize, url, filename}, _from, state),
    do: {:reply, :ok, %{state | authorized_nars: Map.put(state.authorized_nars, url, filename)}}

  def handle_call({:lookup, url}, _from, %{revoked: false} = state),
    do: {:reply, Map.fetch(state.authorized_nars, url), state}

  def handle_call({:lookup, _}, _from, state), do: {:reply, :error, state}

  def handle_call(:stop, _from, state) do
    state = %{state | revoked: true}
    cleanup = teardown(state)
    if cleanup == :ok, do: {:stop, :normal, :ok, state}, else: {:reply, cleanup, state}
  end

  @impl GenServer
  def handle_cast({:unlock, token}, %{validating: token} = state) do
    send(self(), :wake_waiters)
    overhead = max(65_536, directory_bytes(state.directory) - state.used)
    {:noreply, %{state | validating: nil, overhead: overhead}}
  end

  def handle_cast({:unlock, _token}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, _monitor, :process, pid, reason}, state)
      when pid == state.store or pid == state.owner do
    send(state.owner, {:work_store_failed, state.execution_id, reason})
    cleanup = teardown(%{state | revoked: true})

    if cleanup == :ok,
      do: {:stop, :normal, %{state | revoked: true}},
      else: {:noreply, %{state | revoked: true}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    token =
      Enum.find_value(state.uploads, fn {token, upload} ->
        if upload.monitor == monitor, do: token
      end)

    send(self(), :wake_waiters)

    state =
      if token,
        do: discard(state, token),
        else: %{state | waiters: Enum.reject(state.waiters, fn {_, _, ref} -> ref == monitor end)}

    {:noreply, state}
  end

  def handle_info(:wake_waiters, state), do: {:noreply, wake_waiters(state)}

  def handle_info(:deadline, state) do
    send(state.owner, {:work_store_failed, state.execution_id, :deadline})
    cleanup = teardown(%{state | revoked: true})

    if cleanup == :ok,
      do: {:stop, :normal, %{state | revoked: true}},
      else: {:noreply, %{state | revoked: true}}
  end

  def handle_info({:EXIT, _pid, _reason}, %{startup_error: error} = state) when error != nil,
    do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    if pid in state.listeners do
      send(state.owner, {:work_store_failed, state.execution_id, {:listener_down, reason}})
      cleanup = teardown(%{state | revoked: true})

      if cleanup == :ok,
        do: {:stop, :normal, %{state | revoked: true}},
        else: {:noreply, %{state | revoked: true}}
    else
      {:noreply, state}
    end
  end

  defp teardown(state) do
    results =
      Enum.map(state.listeners, fn listener ->
        if Process.alive?(listener) do
          try do
            Supervisor.stop(listener, :normal, :infinity)
          catch
            :exit, reason -> {:error, {:listener_cleanup, reason}}
          end
        else
          :ok
        end
      end)

    # Revocation cancels the worker and waits for its native-tree certificate.
    drained =
      if Process.alive?(state.store),
        do: Garden.WorkStore.revoke(state.store, self()),
        else: {:error, :store_down}

    with true <- Enum.all?(results, &(&1 == :ok)),
         {:ok, paths} <- drained,
         :ok <- remove_sockets(state.sockets),
         :ok <- Garden.WorkStore.Nix.remove_tree(state.directory),
         :ok <- Garden.WorkStore.certify(state.store, self()) do
      if paths != [], do: send(state.owner, {:work_store_paths, state.execution_id, paths})
      :ok
    else
      false -> {:error, :listener_cleanup}
      {:error, reason, _} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_sockets(sockets) do
    Enum.reduce_while(sockets, :ok, fn socket, :ok ->
      case File.lstat(socket) do
        {:ok, %{type: :other}} ->
          case File.rm(socket) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, :enoent} ->
          {:cont, :ok}

        {:ok, _} ->
          {:halt, {:error, :unexpected_socket_file}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp queue_request(state, request, from) do
    if length(state.waiters) >= 16 do
      {:reply, {:error, :busy}, state}
    else
      monitor = Process.monitor(elem(from, 0))
      {:noreply, %{state | waiters: state.waiters ++ [{request, from, monitor}]}}
    end
  end

  defp wake_waiters(%{waiters: []} = state), do: state
  defp wake_waiters(%{revoked: true} = state), do: state

  defp wake_waiters(%{waiters: [{request, from, monitor} | rest]} = state) do
    ready =
      case request do
        :lock ->
          is_nil(state.validating) and map_size(state.uploads) == 0

        {:begin, key, _} ->
          is_nil(state.validating) and map_size(state.uploads) < 8 and
            not Enum.any?(state.uploads, fn {_, upload} -> upload.key == key end)
      end

    if ready do
      Process.demonitor(monitor, [:flush])
      {:reply, result, state} = handle_call(request, from, %{state | waiters: rest})
      GenServer.reply(from, result)
      wake_waiters(state)
    else
      state
    end
  end

  defp discard(state, token) do
    case Map.pop(state.uploads, token) do
      {nil, _} ->
        state

      {upload, uploads} ->
        Process.demonitor(upload.monitor, [:flush])
        result = File.rm(upload.filename)

        used =
          if result in [:ok, {:error, :enoent}], do: state.used - upload.size, else: state.used

        %{state | uploads: uploads, used: used}
    end
  end

  defp directory_bytes(path) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.reduce(names, 0, fn name, total ->
          child = Path.join(path, name)

          case File.lstat(child) do
            {:ok, %{type: :regular, size: size}} -> total + size
            {:ok, %{type: :directory}} -> total + directory_bytes(child)
            _ -> total
          end
        end)

      _ ->
        0
    end
  end
end
