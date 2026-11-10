defmodule VMManager do
  @moduledoc """
  Public interface for defining and operating managed virtual machines.

  Definitions and desired state belong to `VMManager.Manager`; each running
  attempt has a separate execution controller. Guest commands require a
  configured guest agent and a ready session. Stopping a VM and removing its
  definition are separate from deleting explicitly designated persistent disks.
  """

  use TypedStruct

  typedstruct module: Command do
    @moduledoc "A guest command request, including arguments, environment and stdin payload."

    field :path, String.t(), enforce: true
    field :args, [String.t()], default: []
    field :env, map(), default: %{}
    field :stdin, term(), default: %{}
  end

  typedstruct module: Result do
    @moduledoc "A completed guest command's exit status and timing in milliseconds."

    field :code, integer() | nil
    field :signal, integer() | nil
    field :ready_ms, non_neg_integer()
    field :elapsed_ms, non_neg_integer()
  end

  typedstruct module: CommandStatus do
    @moduledoc "The current phase and eventual result of a guest command handle."

    field :phase, atom(), default: :running
    field :result, term()
  end

  typedstruct module: Status do
    @moduledoc """
    Observed VM state, including its configuration, runtime handles and cleanup result.

    Process identifiers describe the current BEAM runtime, not durable ownership.
    A retained phase indicates that cleanup has not been confirmed.
    """

    field :id, String.t()
    field :config, VMManager.Config.t()
    field :desired, atom(), default: :stopped
    field :failure, term()
    field :phase, atom(), default: :stopped
    field :running, boolean(), default: false
    field :directory, String.t()
    field :vmm, pid()
    field :os_pid, pos_integer()
    field :result, term()
    field :cleanup, term(), default: :ok
    field :execution_id, term()
    field :execution, pid()
    field :guard, pid()
    field :owner, pid()
    field :persistent, boolean(), default: true
  end

  def define(%VMManager.Config{} = config, server \\ VMManager.Manager),
    do: GenServer.call(server, {:define, config}, :infinity)

  def update(id, %VMManager.Config{} = config, server \\ VMManager.Manager),
    do: GenServer.call(server, {:update, id, config}, :infinity)

  def start(id, server \\ VMManager.Manager), do: GenServer.call(server, {:start, id}, :infinity)

  @doc """
  Stops a VM with certified cleanup, preserving its definition and persistent disks.

  The default `mode: :graceful` requests guest ACPI shutdown, waiting at most
  `guest_shutdown_timeout_ms` (10,000 by default) before force teardown.
  `mode: :force` bypasses the guest request and wait. Attached VMs use only their
  verified control endpoint; their externally owned VMM process is never killed.
  Attached cleanup requires an observable matching stopped VM; loss of its
  endpoint is uncertain, not proof of teardown. Cloud Hypervisor's
  `--no-shutdown` keeps the external VMM available after guest poweroff.
  Success certifies teardown, not that the guest honored the shutdown request.
  """
  def stop(id, server \\ VMManager.Manager, options \\ []),
    do: GenServer.call(server, {:stop, id, options}, :infinity)

  @doc """
  Abandons a same-boot launch reservation whose controller was lost.

  This is an explicit operator decision, not certified cleanup. No process is
  signaled and no storage or network lease is released. The returned definition
  preserves the abandoned attempt's paths and lease; it is also saved in the
  definition's `abandoned_attempts` list before capacity is released. A later
  explicit start may launch a fresh attempt with the same ID.

  The caller remains responsible for abandoned resources. Removing the
  definition discards its archive metadata without cleaning those resources.
  Updates preserve the archive. `delete_storage/2` rejects definitions with
  archived attempts, even after a later successful cleanup, because persistent
  paths may still belong to abandoned resources.
  Active controllers, unreserved definitions, attachments and reservations from
  another host boot cannot be abandoned through this API.
  """
  def abandon_reservation(id, server \\ VMManager.Manager),
    do: GenServer.call(server, {:abandon_reservation, id}, :infinity)

  def status(id, server \\ VMManager.Manager),
    do: GenServer.call(server, {:status, id}, :infinity)

  def list(server \\ VMManager.Manager), do: GenServer.call(server, :list, :infinity)

  def remove(id, server \\ VMManager.Manager),
    do: GenServer.call(server, {:remove, id}, :infinity)

  def delete_storage(id, server \\ VMManager.Manager),
    do: GenServer.call(server, {:delete_storage, id}, :infinity)

  def subscribe(id, server \\ VMManager.Manager),
    do: GenServer.call(server, {:subscribe, id, self()})

  def await_running(id, server \\ VMManager.Manager),
    do: with_runtime(id, server, &GenServer.call(&1, :await_running, :infinity), false)

  def await_ready(id, server \\ VMManager.Manager),
    do: with_runtime(id, server, &GenServer.call(&1, :await_ready, :infinity), true)

  def execute(id, %Command{} = command, options \\ [], server \\ VMManager.Manager),
    do:
      with_runtime(id, server, &GenServer.call(&1, {:execute, command, options}, :infinity), true)

  def command_status(command), do: GenServer.call(command, :status)
  def await_command(command), do: GenServer.call(command, :await, :infinity)
  def cancel_command(command), do: GenServer.call(command, :cancel)

  defp with_runtime(id, server, fun, requires_guest) do
    result = status(id, server)

    if requires_guest and match?({:ok, %Status{config: %VMManager.Config{guest: :none}}}, result) do
      {:error, :guest_agent_disabled}
    else
      call_runtime(result, fun)
    end
  end

  defp call_runtime(result, fun) do
    with {:ok, %Status{execution: execution, phase: phase}}
         when is_pid(execution) and phase not in [:stopped, :finished, :retained, :failed] <-
           result do
      try do
        fun.(execution)
      catch
        :exit, {reason, {GenServer, :call, _arguments}}
        when reason in [:noproc, :normal, :shutdown, :killed] ->
          {:error, :vm_unavailable}

        :exit, {{:shutdown, _reason}, {GenServer, :call, _arguments}} ->
          {:error, :vm_unavailable}
      end
    else
      {:ok, %Status{phase: phase}} when phase in [:stopped, :finished, :retained, :failed] ->
        {:error, :vm_unavailable}

      {:ok, %Status{result: {:error, _} = error}} ->
        error

      {:ok, %Status{failure: failure}} when not is_nil(failure) ->
        {:error, failure}

      {:ok, _} ->
        {:error, :vm_unavailable}

      error ->
        error
    end
  end

  def validate_command(%Command{} = command) do
    cond do
      not is_binary(command.path) or not String.starts_with?(command.path, "/") ->
        {:error, :invalid_command_path}

      not is_list(command.args) or not Enum.all?(command.args, &is_binary/1) ->
        {:error, :invalid_command_args}

      not is_map(command.env) or
          not Enum.all?(command.env, fn {k, v} ->
            is_binary(k) and is_binary(v) and k != "" and not String.contains?(k, ["=", <<0>>]) and
                not String.contains?(v, <<0>>)
          end) ->
        {:error, :invalid_command_env}

      String.contains?(command.path, <<0>>) or
          Enum.any?(command.args, &String.contains?(&1, <<0>>)) ->
        {:error, :invalid_command_argument}

      true ->
        :ok
    end
  end
end
