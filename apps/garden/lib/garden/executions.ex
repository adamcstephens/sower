defmodule Garden.Executions do
  @moduledoc "Disk custody of server identities, independent of socket lifetime and VM result eviction."
  use GenServer
  use TypedStruct
  alias Garden.VM.Manager

  typedstruct module: Record do
    field :fingerprint, binary()
    field :session, String.t(), enforce: true
    field :attempt, pos_integer(), enforce: true
    field :sequence, non_neg_integer(), default: 0
    field :event, map()
    field :terminal, map()
    field :refused, boolean(), default: false
    field :cancelled, boolean(), default: false
  end

  typedstruct do
    field :table, atom(), enforce: true
    field :session, String.t()
    field :socket_ref, reference()
    field :workers, map(), default: %{}
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def connect(session), do: GenServer.cast(__MODULE__, {:connect, session, self()})
  def disconnect, do: GenServer.cast(__MODULE__, :disconnect)
  def dispatch(payload), do: GenServer.cast(__MODULE__, {:dispatch, payload})
  def cancel(payload), do: GenServer.cast(__MODULE__, {:cancel, payload})

  def stock_image do
    directory = Path.expand("../../share/sower/image", :code.lib_dir(:garden) |> to_string())
    Garden.Image.load(directory)
  end

  @impl GenServer
  def init(_options) do
    directory = Garden.Config.get().state_directory
    File.mkdir_p!(directory)

    {:ok, table} =
      :dets.open_file(__MODULE__,
        file: String.to_charlist(Path.join(directory, "executions.dets")),
        type: :set
      )

    {:ok, %__MODULE__{table: table}}
  end

  @impl GenServer
  def handle_call({:event, sid, kind, attrs}, _from, %__MODULE__{} = state) do
    {:reply, publish(state, sid, kind, attrs), state}
  end

  @impl GenServer
  def handle_cast({:connect, session, socket}, %__MODULE__{} = state) do
    Enum.each(state.workers, fn {_sid, {pid, _ref}} -> send(pid, :cancel) end)
    if state.socket_ref, do: Process.demonitor(state.socket_ref, [:flush])
    state = %{state | session: session, socket_ref: Process.monitor(socket)}
    service = self()

    records =
      :dets.foldl(
        fn {sid, record}, acc ->
          if Map.has_key?(state.workers, sid), do: acc, else: [{sid, record} | acc]
        end,
        [],
        state.table
      )

    Task.Supervisor.start_child(Garden.TaskSupervisor, fn ->
      result =
        Enum.reduce_while(records, :ok, fn {sid, record}, :ok ->
          response =
            case record.terminal do
              %{kind: "result"} = event ->
                Garden.Socket.execution_event(event)

              _ ->
                emit(service, sid, "result", %{
                  result: %{
                    error: "custody_lost",
                    cleanup: "unknown"
                  }
                })
            end

          case response do
            {:ok, _} -> {:cont, :ok}
            {:error, _} -> {:halt, :error}
          end
        end)

      send(socket, {if(result == :ok, do: :builder_ready, else: :builder_failed), session})
    end)

    {:noreply, state}
  end

  def handle_cast(:disconnect, %__MODULE__{} = state) do
    Enum.each(state.workers, fn {_sid, {pid, _ref}} -> send(pid, :cancel) end)
    {:noreply, %{state | session: nil}}
  end

  def handle_cast(
        {:cancel, %{"sid" => sid, "session" => session, "attempt" => attempt}},
        %__MODULE__{} = state
      ) do
    if session == state.session do
      case :dets.lookup(state.table, sid) do
        [] ->
          record = %Record{session: session, attempt: attempt, cancelled: true}
          store(state, sid, record)
          publish(state, sid, "result", %{result: %{error: "cancelled", cleanup: "complete"}})

        [{^sid, %Record{attempt: ^attempt} = record}] ->
          case state.workers[sid] do
            {pid, _ref} -> send(pid, :cancel)
            nil -> if record.terminal, do: Garden.Socket.execution_event(record.terminal)
          end

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast({:dispatch, payload}, %__MODULE__{} = state) do
    with {:ok, request} <- SowerClient.Execution.Dispatch.cast(payload),
         true <- request.session == state.session,
         true <- Garden.Config.get().builder,
         true <- request.request.network != "full" or Garden.Config.get().builder_network do
      sid = request.sid

      fingerprint =
        :crypto.hash(:sha256, :erlang.term_to_binary({request.run_sid, request.request}))

      case :dets.lookup(state.table, sid) do
        [] ->
          {:noreply, start_request(state, request, fingerprint)}

        [{^sid, %Record{fingerprint: ^fingerprint, refused: true, attempt: attempt}}]
        when attempt < request.attempt ->
          {:noreply, start_request(state, request, fingerprint)}

        [{^sid, %Record{fingerprint: ^fingerprint} = record}] ->
          cond do
            record.terminal || record.event ->
              Garden.Socket.execution_event(record.terminal || record.event)

            Map.has_key?(state.workers, sid) ->
              :ok

            true ->
              publish(state, sid, "result", %{
                result: %{error: "custody_lost", cleanup: "unknown"}
              })
          end

          {:noreply, state}

        [{^sid, %Record{cancelled: true}}] ->
          publish(state, sid, "result", %{result: %{error: "cancelled", cleanup: "complete"}})
          {:noreply, state}

        [_] ->
          publish(state, sid, "conflict", %{
            result: %{error: "identity_conflict", cleanup: "unknown"}
          })

          {:noreply, state}
      end
    else
      _ -> {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{socket_ref: ref} = state) do
    handle_cast(:disconnect, %{state | socket_ref: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{} = state) do
    Enum.each(state.workers, fn {sid, {_pid, worker_ref}} ->
      if ref == worker_ref and reason != :normal do
        [{^sid, record}] = :dets.lookup(state.table, sid)

        unless record.terminal do
          publish(state, sid, "result", %{
            result: %{error: "worker_lost", detail: inspect(reason), cleanup: "unknown"}
          })
        end
      end
    end)

    workers = Map.reject(state.workers, fn {_sid, {_pid, worker_ref}} -> ref == worker_ref end)
    {:noreply, %{state | workers: workers}}
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{} = state), do: :dets.close(state.table)

  defp start_request(
         %__MODULE__{} = state,
         %SowerClient.Execution.Dispatch{} = request,
         fingerprint
       ) do
    record = %Record{fingerprint: fingerprint, session: request.session, attempt: request.attempt}
    store(state, request.sid, record)
    service = self()
    {pid, ref} = spawn_monitor(fn -> run(service, request.sid, request.request) end)
    %{state | workers: Map.put(state.workers, request.sid, {pid, ref})}
  end

  defp publish(%__MODULE__{} = state, sid, kind, attrs) do
    [{^sid, record}] = :dets.lookup(state.table, sid)

    event =
      Map.merge(
        %{
          sid: sid,
          session: record.session,
          attempt: record.attempt,
          sequence: record.sequence + 1,
          kind: kind
        },
        attrs
      )

    record = %{
      record
      | sequence: event.sequence,
        event: event,
        refused: record.refused or kind == "refused",
        terminal: if(kind == "result", do: event, else: record.terminal)
    }

    store(state, sid, record)

    if record.session == state.session or (kind == "result" and state.session),
      do: Garden.Socket.execution_event(event),
      else: {:error, :disconnected}
  end

  defp store(%__MODULE__{} = state, sid, %Record{} = record) do
    :ok = :dets.insert(state.table, {sid, record})
    :ok = :dets.sync(state.table)
  end

  defp emit(service, sid, kind, attrs \\ %{}),
    do: GenServer.call(service, {:event, sid, kind, attrs}, :infinity)

  defp run(service, sid, %SowerClient.Execution.Request{} = request) do
    service_ref = Process.monitor(service)

    command = %Garden.VM.Command{
      path: request.path,
      args: request.args,
      env: request.env,
      stdin: request.stdin
    }

    worker = self()

    callback = fn stream, bytes ->
      send(worker, :ready)

      {:ok, _reply} =
        emit(service, sid, "log", %{stream: to_string(stream), bytes: Base.encode64(bytes)})
    end

    with {:ok, image} <- stock_image(),
         {:ok, id} <-
           Manager.start(
             image: image,
             command: command,
             owner: self(),
             result_recipient: self(),
             cpus: request.cpus,
             memory: request.memory,
             scratch_bytes: request.scratch_bytes,
             deadline_ms: request.timeout_ms,
             network: if(request.network == "full", do: :full, else: :none),
             on_output: callback
           ) do
      {:ok, _reply} = emit(service, sid, "accepted")
      wait(service, service_ref, sid, id, false)
    else
      {:error, {reason, _dimension}}
      when reason in [:capacity_exhausted, :request_exceeds_capacity] ->
        emit(service, sid, "refused")

      {:error, :draining} ->
        emit(service, sid, "refused")

      {:error, reason} ->
        emit(service, sid, "result", %{
          result: %{error: "startup", detail: inspect(reason), cleanup: "complete"}
        })
    end
  end

  defp wait(service, service_ref, sid, id, running) do
    receive do
      :cancel ->
        Manager.cancel(id)
        wait(service, service_ref, sid, id, running)

      {:DOWN, ^service_ref, :process, _, _} ->
        Manager.cancel(id)
        Manager.await(id)

      :ready ->
        unless running, do: emit(service, sid, "running")
        wait(service, service_ref, sid, id, true)

      {:vm_terminal, ^id, %Garden.VM.Status{} = status} ->
        outcome =
          case status.result do
            {:error, {:cleanup_unconfirmed, outcome, _cleanup, _directory}} -> outcome
            outcome -> outcome
          end

        result =
          case outcome do
            {:ok, %Garden.VM.Result{} = result} ->
              unless running, do: emit(service, sid, "running")

              %{
                code: result.code,
                signal: result.signal,
                ready_ms: result.ready_ms,
                elapsed_ms: result.elapsed_ms
              }

            {:error, reason} ->
              error_result(reason)
          end

        result =
          Map.merge(result, %{
            cleanup: if(status.cleanup == :ok, do: "complete", else: "incomplete"),
            cleanup_error: if(status.cleanup != :ok, do: inspect(status.cleanup))
          })

        emit(service, sid, "result", %{result: result})
    after
      50 ->
        running =
          case Manager.status(id) do
            {:ok, %{phase: :running}} when not running ->
              emit(service, sid, "running")
              true

            _ ->
              running
          end

        wait(service, service_ref, sid, id, running)
    end
  end

  defp error_result(:cancelled), do: %{error: "cancelled"}
  defp error_result(:timeout), do: %{error: "execution_timeout"}
  defp error_result({:guest, message}), do: %{error: "guest", detail: message}

  defp error_result({kind, reason})
       when kind in [:guest_protocol, :unexpected_guest_event, :unexpected_ready_event],
       do: %{error: "guest_protocol", detail: inspect(reason)}

  defp error_result({kind, reason})
       when kind in [:scratch_startup, :mkfs, :resource_directory],
       do: %{error: "startup", detail: inspect(reason)}

  defp error_result({:vmm_failed, {:startup, message}}), do: %{error: "startup", detail: message}
  defp error_result(reason), do: %{error: "execution_failed", detail: inspect(reason)}
end
