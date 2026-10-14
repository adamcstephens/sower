defmodule Garden.VM do
  @moduledoc """
  Local image command execution with optional host-isolated networking.

  Load metadata with `Garden.Image.load/1`, then start a caller-supervised execution with
  `start_link(image: image, command: %Command{}, ...)`. `status/1` remains
  inspectable; `await/1` waits for certified teardown. `cancel/1` initiates
  independent teardown. `run/3` is the synchronous convenience boundary.
  `on_output` receives `(stream, bytes)` in the I/O worker, applying bounded
  backpressure without blocking cancellation or the execution deadline.
  `network: :none` is the default and supplies no NIC. `network: :full` requires
  the operator-enabled activator network requests; its execution-scoped lease
  owns a routed TAP and host-enforced public-egress policy. `:activator_socket`
  selects the local activator socket. No privileged fallback is used.
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
  end

  def start_link(options), do: Garden.VM.Execution.start_link(options)
  def child_spec(options), do: Garden.VM.Execution.child_spec(options)
  def status(server), do: GenServer.call(server, :status)
  def await(server), do: GenServer.call(server, :await, :infinity)
  def cancel(server), do: GenServer.call(server, :cancel)

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
