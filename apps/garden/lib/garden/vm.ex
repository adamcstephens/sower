defmodule Garden.VM do
  @moduledoc """
  Garden-owned image VMs with serial, independently cancellable commands.

  `boot/2` and `await_ready/1` provision a contract-2 guest without a workload.
  `execute/3` returns a command handle; `await_command/1`, `command_status/1`
  and `cancel_command/1` operate on that command. Completion leaves the VM
  ready, preserving its scratch state and admission reservation. `stop/1`
  waits for certified teardown. `:owner` defaults to the boot caller.
  Command caller loss cancels only its command, not the owned VM.

  `start_link(image: image, command: %Command{}, ...)` and `run/3` compose
  the same lifecycle for disposable execution, including contract-1 images.
  Their `await/1` waits for VM teardown; `cancel/1` initiates VM teardown.
  Persistent phases are `:booting`, `:ready`, `:running_command`, `:stopping`,
  `:stopped` and `:retained` (uncertain cleanup, never intentional idleness).
  `:boot_deadline_ms` bounds readiness; command `:deadline_ms` is independent.
  `on_output` receives `(stream, bytes)` with bounded backpressure in a
  separate worker; cancellation and VM stop do not wait for that callback.

  `network: :none` supplies no NIC. `network: :full` requires the operator's
  activator network support and keeps its execution-scoped lease until VM
  teardown. `:activator_socket` selects that socket; no privileged fallback.
  This is development orchestration, not a production sandbox.
  """
  use TypedStruct
  alias Garden.Image

  typedstruct module: Command do
    field :path, String.t(), enforce: true
    field :args, [String.t()], default: []
    field :env, map(), default: %{}
    field :stdin, term(), default: %{}
  end

  typedstruct module: Result do
    field :code, integer() | nil
    field :signal, integer() | nil
    field :ready_ms, non_neg_integer()
    field :elapsed_ms, non_neg_integer()
  end

  typedstruct module: CommandStatus do
    field :phase, atom(), default: :running
    field :result, term()
  end

  typedstruct module: Status do
    field :phase, atom(), default: :starting
    field :directory, String.t()
    field :vmm, pid()
    field :os_pid, pos_integer()
    field :result, term()
    field :cleanup, term()
    field :execution_id, integer()
    field :execution, pid()
    field :guard, pid()
    field :owner, pid()
    field :persistent, boolean(), default: false
  end

  def start_link(options), do: Garden.VM.Execution.start_link(options)
  def child_spec(options), do: Garden.VM.Execution.child_spec(options)
  def status(server), do: GenServer.call(server, :status)
  def await(server), do: GenServer.call(server, :await, :infinity)
  def cancel(server), do: GenServer.call(server, :cancel)

  def boot(%Image{} = image, options \\ []),
    do: start_link(Keyword.merge(options, image: image) |> Keyword.delete(:command))

  def await_ready(server), do: GenServer.call(server, :await_ready, :infinity)

  def execute(server, %Command{} = command, options \\ []),
    do: GenServer.call(server, {:execute, command, options}, :infinity)

  def command_status(command), do: GenServer.call(command, :status)
  def await_command(command), do: GenServer.call(command, :await, :infinity)
  def cancel_command(command), do: GenServer.call(command, :cancel)
  def stop(server), do: GenServer.call(server, :stop, :infinity)

  def run(%Image{} = image, %Command{} = command, options \\ []) do
    with {:ok, server} <- start_link(Keyword.merge(options, image: image, command: command)) do
      try do
        await(server)
      after
        GenServer.stop(server)
      end
    else
      {:error, reason} -> {:error, reason}
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
