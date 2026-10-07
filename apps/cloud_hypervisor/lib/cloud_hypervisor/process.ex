defmodule CloudHypervisor.Process do
  @moduledoc """
  Caller-supervised ownership of one Cloud Hypervisor process tree.

  `start_link/1` accepts `launch: %Launch{}`, `config: %Config{}`, `mode: :cli`
  (the default) or `:api`, `owner: pid` (the caller by default), and a positive
  `readiness_timeout` in milliseconds (5,000 by default). The child is temporary.
  An explicit owner is monitored even when a supervisor starts the server.

  `client/1` returns `{:ok, %API{}}`. `status/1` returns a `Status` struct.
  `await_ready/1` returns `{:ok, status}` only after the API is responsive and
  `vm.info` reports `Running`, or `{:error, reason}` after failed startup.
  Tree cleanup is confirmed unless the error reports incomplete cleanup.
  API mode performs create/boot;
  CLI mode supplies the configuration at launch. Neither means the guest's
  userspace is ready. `api_ready` and `vm_state` are cached startup observations,
  not guest-runtime readiness or live state after standalone API mutations.
  Use `API.info(client)` for the VM's current state.

  `stop/2` returns `{:ok, {:exit_status, integer} | {:signal, integer}}` only
  after Rexec confirms that its owned tree has been reaped. Graceful stop
  requests API VMM shutdown, then escalates to `Rexec.kill_tree/2` after
  500 ms. Force stop immediately kills the tree. Cleanup allows Rexec's
  five-second deadline and delivery grace. Unconfirmed cleanup returns
  `{:error, :shutdown_timeout}` or `{:error, {:cleanup_failed, message}}`
  and retains the execution directory. A cleanup failure remains a failure
  even if Rexec subsequently exits. Startup execution errors use
  `{:startup, message}`; only an empty directory is removed in that case.
  A nonempty startup directory or Rexec cleanup notice is reported as
  `{:cleanup_failed, message}` and retained.
  Stopping the VM alone remains `API.shutdown(client)`, not `stop/2`.

  The owner receives `{:cloud_hypervisor, server, event}`. Events are
  `{:stdout, bytes}`, `{:stderr, bytes}`, `{:api_ready, status}`,
  `{:ready, status}`, `{:failed, reason}`, and
  `{:exited, {:exit_status, integer} | {:signal, integer}}`.
  The server remains inspectable after native exit, until its owner dies or
  its supervisor shuts it down. It does not restart the VMM.

  API and optional vsock sockets live in an exclusively created 0700 execution
  directory. Supply no launch API socket, and use `socket: nil` for an owned
  vsock device. Caller-supplied API/vsock paths are rejected, never removed.
  Other configured paths, including serial/console sockets, remain caller-owned.
  An independent, unlinked cleanup owner starts Rexec as its linked caller before
  execution begins. It forwards output and terminal status, surviving lifecycle
  server death and reclaiming only owned sockets and the private directory after
  certified tree completion. Requires Rexec's Linux 5.3+, pidfd, and readable
  `/proc` support. This is not a sandbox or system-wide crash reconciler.
  Unexpected Rexec death is not proof of cleanup and retains owned sockets.
  Standalone `API` clients may still address arbitrary sockets.
  """

  use GenServer
  use TypedStruct

  alias CloudHypervisor.{API, CLI, Cleanup, Config, Launch}
  alias Elixir.Process, as: BEAM

  @grace_timeout 500
  @cleanup_timeout 5_500
  @call_timeout @grace_timeout + @cleanup_timeout + 1_000
  @server_shutdown @cleanup_timeout + 500

  typedstruct module: Status do
    field :phase, :starting | :ready | :stopping | :exited | :failed, default: :starting
    field :mode, :cli | :api, enforce: true
    field :directory, String.t(), enforce: true
    field :os_pid, pos_integer()
    field :api_ready, boolean(), default: false
    field :vm_state, String.t()
    field :outcome, {:exit_status, integer()} | {:signal, integer()}
    field :error, term()
  end

  typedstruct module: Request do
    field :pid, pid(), enforce: true
    field :monitor, reference(), enforce: true
    field :kind, :ping | :create | :boot | :info | :shutdown, enforce: true
  end

  typedstruct module: State do
    field :status, Status.t(), enforce: true
    field :launch, Launch.t(), enforce: true
    field :config, Config.t(), enforce: true
    field :client, API.t(), enforce: true
    field :owner, pid(), enforce: true
    field :owner_monitor, reference(), enforce: true
    field :owner_dead, boolean(), default: false
    field :runner, pid()
    field :cleanup_error, String.t()
    field :deadline, integer(), enforce: true
    field :readiness_timer, reference()
    field :shutdown_timer, reference()
    field :request, Request.t()
    field :startup_result, term()
    field :startup_waiters, [GenServer.from()], default: []
    field :stop_waiters, [GenServer.from()], default: []
    field :stop_stage, :graceful | :force
  end

  def start_link(options) do
    options = Keyword.put_new(options, :owner, self())

    case validate(options) do
      {:ok, _launch, _config, _mode, _owner, _timeout} = settings ->
        GenServer.start_link(__MODULE__, settings, Keyword.take(options, [:name]))

      {:error, reason} ->
        {:error, reason}
    end
  end

  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      shutdown: @server_shutdown
    }
  end

  def client(server), do: GenServer.call(server, :client, @call_timeout)
  def status(server), do: GenServer.call(server, :status, @call_timeout)
  def await_ready(server), do: GenServer.call(server, :await_ready, :infinity)

  def stop(server, mode) when mode in [:graceful, :force],
    do: GenServer.call(server, {:stop, mode}, @call_timeout)

  @impl GenServer
  def init({:ok, launch, config, mode, owner, timeout}) do
    BEAM.flag(:trap_exit, true)

    with {:ok, cleanup_owner, directory} <- Cleanup.prepare(&execution_directory/0) do
      launch = %{launch | api_socket: Path.join(directory, "api.sock")}
      config = own_vsock(config, directory)
      client = %API{socket: launch.api_socket, timeout: min(timeout, 1_000)}
      status = %Status{directory: directory, mode: mode}
      owner_monitor = BEAM.monitor(owner)

      state = %State{
        status: status,
        launch: launch,
        config: config,
        client: client,
        owner: owner,
        owner_monitor: owner_monitor,
        deadline: now() + timeout
      }

      case run(cleanup_owner, launch, config, mode) do
        {:ok, runner, os_pid} ->
          timer = BEAM.send_after(self(), :readiness_timeout, timeout)

          state = %{
            state
            | status: %{status | os_pid: os_pid},
              runner: runner,
              deadline: now() + timeout,
              readiness_timer: timer
          }

          {:ok, request(state, :ping)}

        {:error, reason} ->
          state = %{state | status: %{status | phase: :failed, error: reason}}

          state =
            receive do
              {:cleanup_error, _os_pid, message} -> cleanup_failed(state, message)
            after
              0 ->
                notify(state, {:failed, reason})
                finish_startup(state, {:error, reason})
            end

          {:ok, state}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:client, _from, %State{} = state), do: {:reply, {:ok, state.client}, state}
  def handle_call(:status, _from, %State{} = state), do: {:reply, state.status, state}

  def handle_call(:await_ready, from, %State{startup_result: nil} = state) do
    {:noreply, %{state | startup_waiters: [from | state.startup_waiters]}}
  end

  def handle_call(:await_ready, _from, %State{} = state),
    do: {:reply, state.startup_result, state}

  def handle_call({:stop, _mode}, _from, %State{cleanup_error: message} = state)
      when not is_nil(message),
      do: {:reply, {:error, {:cleanup_failed, message}}, state}

  def handle_call({:stop, _mode}, _from, %State{runner: nil} = state) do
    {:reply, stop_result(state), state}
  end

  def handle_call({:stop, _mode}, _from, %State{stop_stage: :force, shutdown_timer: nil} = state),
    do: {:reply, {:error, :shutdown_timeout}, state}

  def handle_call({:stop, mode}, from, %State{} = state) do
    state = %{state | stop_waiters: [from | state.stop_waiters]}
    {:noreply, begin_stop(state, mode, {:stopped, mode})}
  end

  @impl GenServer
  def handle_info({stream, os_pid, bytes}, %State{status: %Status{os_pid: os_pid}} = state)
      when stream in [:stdout, :stderr] do
    notify(state, {stream, bytes})
    {:noreply, state}
  end

  def handle_info({:cleanup_error, _os_pid, message}, %State{} = state) do
    {:noreply, cleanup_failed(state, message)}
  end

  def handle_info({:EXIT, runner, reason}, %State{runner: runner} = state) do
    state = complete_exit(state, reason)
    if state.owner_dead, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:request_result, pid, result}, %State{request: %Request{pid: pid}} = state) do
    kind = state.request.kind
    BEAM.demonitor(state.request.monitor, [:flush])
    state = %{state | request: nil}
    {:noreply, request_result(state, kind, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{owner_monitor: ref} = state) do
    state = %{state | owner_dead: true}

    if state.runner == nil,
      do: {:stop, :normal, state},
      else: {:noreply, begin_stop(state, :force, :owner_down)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{request: %Request{monitor: ref}} = state
      ) do
    kind = state.request.kind
    state = %{state | request: nil}
    {:noreply, request_result(state, kind, {:error, {:request_crashed, reason}})}
  end

  def handle_info(:poll, %State{status: %Status{phase: :starting}} = state) do
    kind = if state.status.api_ready, do: :info, else: :ping
    {:noreply, request(state, kind)}
  end

  def handle_info(:readiness_timeout, %State{status: %Status{phase: :starting}} = state) do
    {:noreply, begin_stop(state, :force, :readiness_timeout)}
  end

  def handle_info(:force_stop, %State{stop_stage: :graceful} = state) do
    {:noreply, force_stop(state)}
  end

  def handle_info(
        :shutdown_timeout,
        %State{runner: runner, stop_stage: :force, cleanup_error: nil} = state
      )
      when not is_nil(runner) do
    Enum.each(state.stop_waiters, &GenServer.reply(&1, {:error, :shutdown_timeout}))

    state = %{
      state
      | status: %{state.status | error: :shutdown_timeout},
        stop_waiters: [],
        shutdown_timer: nil
    }

    {:noreply, finish_startup(state, {:error, :shutdown_timeout})}
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    cancel_request(state)
    cancel_timer(state.readiness_timer)
    cancel_timer(state.shutdown_timer)

    if state.runner != nil do
      deadline = now() + @cleanup_timeout

      try do
        GenServer.stop(state.runner, :normal, @cleanup_timeout)
      catch
        :exit, _reason -> :ok
      end

      case await_runner_termination(state, deadline) do
        :ok ->
          :ok

        {:error, message} ->
          if state.cleanup_error == nil, do: notify(state, {:failed, {:cleanup_failed, message}})
          exit({:shutdown, {:cleanup_failed, message}})
      end
    end
  end

  defp validate(options) do
    launch = Keyword.get(options, :launch, %Launch{})
    config = Keyword.get(options, :config)
    mode = Keyword.get(options, :mode, :cli)
    owner = Keyword.get(options, :owner)
    timeout = Keyword.get(options, :readiness_timeout, 5_000)

    cond do
      not match?(%Launch{}, launch) -> {:error, {:invalid_option, :launch}}
      not match?(%Config{}, config) -> {:error, {:invalid_option, :config}}
      mode not in [:cli, :api] -> {:error, {:invalid_option, :mode}}
      not is_pid(owner) -> {:error, {:invalid_option, :owner}}
      not is_integer(timeout) or timeout <= 0 -> {:error, {:invalid_option, :readiness_timeout}}
      not is_nil(launch.api_socket) -> {:error, {:caller_socket, :api_socket}}
      not is_nil(get_in(config.vsock.socket)) -> {:error, {:caller_socket, :vsock}}
      get_in(config.console.mode) == :socket -> {:error, {:invalid_option, :console}}
      true -> {:ok, launch, config, mode, owner, timeout}
    end
  end

  defp execution_directory do
    directory =
      Path.join(
        System.tmp_dir!(),
        "cloud-hypervisor-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    case File.mkdir(directory) do
      :ok ->
        case File.chmod(directory, 0o700) do
          :ok ->
            {:ok, directory}

          {:error, reason} ->
            File.rmdir(directory)
            {:error, {:execution_directory, reason}}
        end

      {:error, :eexist} ->
        execution_directory()

      {:error, reason} ->
        {:error, {:execution_directory, reason}}
    end
  end

  defp own_vsock(%Config{vsock: nil} = config, _directory), do: config

  defp own_vsock(%Config{} = config, directory) do
    %{config | vsock: %{config.vsock | socket: Path.join(directory, "vsock.sock")}}
  end

  defp run(cleanup_owner, %Launch{} = launch, %Config{} = config, mode) do
    {executable, arguments} =
      if mode == :cli, do: CLI.command(launch, config), else: CLI.command(launch)

    Cleanup.run(cleanup_owner, [executable | arguments])
  end

  defp request(%State{request: %Request{}} = state, _kind), do: state

  defp request(%State{} = state, kind) do
    parent = self()

    timeout =
      if kind == :shutdown,
        do: @grace_timeout,
        else: max(1, min(state.client.timeout, state.deadline - now()))

    client = %{state.client | timeout: timeout}
    config = state.config

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          case kind do
            :ping -> API.ping(client)
            :create -> API.create(client, config)
            :boot -> API.boot(client)
            :info -> API.info(client)
            :shutdown -> API.shutdown_vmm(client)
          end

        send(parent, {:request_result, self(), result})
      end)

    %{state | request: %Request{pid: pid, monitor: monitor, kind: kind}}
  end

  defp request_result(%State{status: %Status{phase: :stopping}} = state, :shutdown, :ok),
    do: state

  defp request_result(%State{status: %Status{phase: :stopping}} = state, :shutdown, _error) do
    Rexec.kill(state.runner, :sigterm)
    state
  end

  defp request_result(%State{status: %Status{phase: phase}} = state, _kind, _result)
       when phase != :starting, do: state

  defp request_result(%State{} = state, :ping, {:ok, %API.Ping{}}) do
    state = %{state | status: %{state.status | api_ready: true}}
    notify(state, {:api_ready, state.status})
    request(state, if(state.status.mode == :api, do: :create, else: :info))
  end

  defp request_result(%State{} = state, :create, :ok), do: request(state, :boot)
  defp request_result(%State{} = state, :boot, :ok), do: request(state, :info)

  defp request_result(%State{} = state, :info, {:ok, %API.Info{state: "Running"}}) do
    cancel_timer(state.readiness_timer)

    state = %{
      state
      | status: %{state.status | phase: :ready, vm_state: "Running"},
        readiness_timer: nil
    }

    notify(state, {:ready, state.status})
    finish_startup(state, {:ok, state.status})
  end

  defp request_result(%State{} = state, :info, {:ok, %API.Info{} = info}) do
    schedule_poll(%{state | status: %{state.status | vm_state: info.state}})
  end

  defp request_result(%State{} = state, :ping, {:error, %API.Error{kind: :transport}}),
    do: schedule_poll(state)

  defp request_result(%State{} = state, kind, {:error, reason}),
    do: begin_stop(state, :force, {:startup, kind, reason})

  defp schedule_poll(%State{} = state) do
    BEAM.send_after(self(), :poll, 25)
    state
  end

  defp begin_stop(%State{runner: nil} = state, _mode, _reason), do: state
  defp begin_stop(%State{stop_stage: :force} = state, _mode, _reason), do: state
  defp begin_stop(%State{stop_stage: :graceful} = state, :graceful, _reason), do: state
  defp begin_stop(%State{stop_stage: :graceful} = state, :force, _reason), do: force_stop(state)

  defp begin_stop(%State{} = state, mode, reason) do
    cancel_timer(state.readiness_timer)
    cancel_request(state)
    error = if state.startup_result == nil, do: reason, else: state.status.error

    state = %{
      state
      | status: %{state.status | phase: :stopping, error: error},
        readiness_timer: nil,
        request: nil
    }

    if mode == :force do
      force_stop(state)
    else
      timer = BEAM.send_after(self(), :force_stop, @grace_timeout)
      state = %{state | stop_stage: :graceful, shutdown_timer: timer}

      if state.status.api_ready,
        do: request(state, :shutdown),
        else:
          (
            Rexec.kill(state.runner, :sigterm)
            state
          )
    end
  end

  defp force_stop(%State{} = state) do
    cancel_timer(state.shutdown_timer)
    cancel_request(state)
    Rexec.kill_tree(state.runner, :sigkill)
    timer = BEAM.send_after(self(), :shutdown_timeout, @cleanup_timeout)
    %{state | stop_stage: :force, shutdown_timer: timer, request: nil}
  end

  defp complete_exit(%State{} = state, reason) do
    cancel_timer(state.readiness_timer)
    cancel_timer(state.shutdown_timer)
    cancel_request(state)

    {outcome, cleanup_error} =
      case completion(reason) do
        {:ok, outcome} when state.cleanup_error == nil ->
          {outcome, nil}

        {:ok, _outcome} ->
          {nil, state.cleanup_error}

        {:error, message} ->
          {nil, state.cleanup_error || message}
      end

    error =
      if cleanup_error,
        do: {:cleanup_failed, cleanup_error},
        else: state.status.error

    phase =
      if error != nil and not match?({:stopped, _}, error) and error != :owner_down,
        do: :failed,
        else: :exited

    status = %{state.status | phase: phase, error: error, outcome: outcome}
    notified_cleanup_error = state.cleanup_error != nil

    state = %{
      state
      | status: status,
        runner: nil,
        cleanup_error: cleanup_error,
        request: nil,
        readiness_timer: nil,
        shutdown_timer: nil
    }

    if outcome != nil, do: notify(state, {:exited, outcome})
    if phase == :failed and not notified_cleanup_error, do: notify(state, {:failed, error})
    state = finish_startup(state, {:error, error || {:exited, outcome}})
    Enum.each(state.stop_waiters, &GenServer.reply(&1, stop_result(state)))
    %{state | stop_waiters: []}
  end

  defp cleanup_failed(%State{cleanup_error: nil} = state, message) do
    cancel_timer(state.readiness_timer)
    cancel_timer(state.shutdown_timer)
    cancel_request(state)
    error = {:cleanup_failed, message}

    state = %{
      state
      | status: %{state.status | phase: :failed, error: error, outcome: nil},
        cleanup_error: message,
        request: nil,
        readiness_timer: nil,
        shutdown_timer: nil,
        stop_stage: :force
    }

    notify(state, {:failed, error})
    state = finish_startup(state, {:error, error})
    Enum.each(state.stop_waiters, &GenServer.reply(&1, {:error, error}))
    %{state | stop_waiters: []}
  end

  defp cleanup_failed(%State{} = state, _message), do: state

  defp completion(reason), do: Cleanup.completion(reason)

  defp finish_startup(%State{startup_result: nil} = state, result) do
    Enum.each(state.startup_waiters, &GenServer.reply(&1, result))
    %{state | startup_result: result, startup_waiters: []}
  end

  defp finish_startup(%State{} = state, _result), do: state

  defp stop_result(%State{status: %Status{outcome: nil}} = state),
    do: {:error, state.status.error}

  defp stop_result(%State{} = state), do: {:ok, state.status.outcome}
  defp notify(%State{} = state, event), do: send(state.owner, {:cloud_hypervisor, self(), event})
  defp now, do: System.monotonic_time(:millisecond)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: BEAM.cancel_timer(timer)
  defp cancel_request(%State{request: nil}), do: :ok

  defp cancel_request(%State{} = state) do
    BEAM.demonitor(state.request.monitor, [:flush])
    BEAM.exit(state.request.pid, :kill)
  end

  defp await_runner_termination(%State{} = state, deadline) do
    receive do
      {stream, os_pid, bytes}
      when stream in [:stdout, :stderr] and os_pid == state.status.os_pid ->
        notify(state, {stream, bytes})
        await_runner_termination(state, deadline)

      {:cleanup_error, _os_pid, message} ->
        await_runner_termination(
          %{state | cleanup_error: state.cleanup_error || message},
          deadline
        )

      {:EXIT, runner, reason} when runner == state.runner ->
        case completion(reason) do
          {:ok, _outcome} when state.cleanup_error == nil ->
            :ok

          {:ok, _outcome} ->
            {:error, state.cleanup_error}

          {:error, message} ->
            {:error, state.cleanup_error || message}
        end
    after
      max(0, deadline - now()) ->
        {:error,
         state.cleanup_error ||
           "Rexec did not confirm complete process-tree cleanup before the shutdown deadline"}
    end
  end
end
