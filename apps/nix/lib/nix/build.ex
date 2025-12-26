defmodule Nix.Build do
  @moduledoc """
  Runs `nix-build` on a derivation path and returns the result.
  """
  use GenServer
  use TypedStruct

  alias Nix.Build

  require Logger

  @default_timeout_ms 60 * 60 * 1000

  typedstruct do
    field :eval, Nix.Eval.t()
    field :drv_path, binary() | nil, default: nil
    field :store_path, binary() | nil, default: nil
    field :start_time, DateTime.t()
    field :end_time, DateTime.t()
    field :status, :ok | :error | :timeout
    field :errors, list(binary()), default: []
  end

  typedstruct module: Exec do
    field :build, Nix.Build.t()
    field :extra_args, list(binary()), default: []
    field :from, {pid(), term()}
    field :pid, pid()
    field :ospid, integer()
    field :stdout, list(binary()), default: []
    field :stderr, list(binary()), default: []
  end

  @doc """
  Build a derivation by its path.

  Returns `{:ok, %Nix.Build{}}` on success or `{:error, %Nix.Build{}}` on failure.

  ## Options
  - `:timeout` - Build timeout in milliseconds (default: 1 hour)
  - `:extra_args` - Additional arguments to pass to nix-build

  ## Examples

      {:ok, build} = Nix.Build.run("/nix/store/abc123-foo.drv")
      build.store_path  # => "/nix/store/xyz789-foo"
  """
  def run(%Nix.Eval{} = eval, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    {:ok, pid} = GenServer.start_link(Build, {eval, opts})
    GenServer.call(pid, :run, timeout)
  end

  def run!(eval, opts \\ []) do
    {:ok, eval} = run(eval, opts)
    eval
  end

  def init({%Nix.Eval{} = eval, opts}) do
    Process.flag(:trap_exit, true)

    state = %Build.Exec{
      build: %Build{eval: eval, drv_path: eval.output["drvPath"]},
      extra_args: Keyword.get(opts, :extra_args, [])
    }

    {:ok, state}
  end

  def handle_call(:run, from, %Build.Exec{} = state) do
    start_time = DateTime.utc_now()

    cmd =
      [
        System.find_executable("nix-build"),
        state.build.drv_path,
        "--no-out-link"
      ] ++ state.extra_args

    Logger.debug(
      msg: "Running build",
      cmd: Enum.join(cmd, " "),
      drv_path: state.build.drv_path
    )

    {:ok, pid, ospid} =
      :exec.run_link(
        cmd,
        [
          :stdout,
          :stderr
        ]
      )

    state = %{
      state
      | pid: pid,
        ospid: ospid,
        from: from,
        build: %{state.build | start_time: start_time}
    }

    {:noreply, state}
  end

  def handle_info({:stdout, ospid, stdout}, %Build.Exec{ospid: ospid} = state) do
    {:noreply, %{state | stdout: [stdout | state.stdout]}}
  end

  def handle_info({:stderr, ospid, stderr}, %Build.Exec{ospid: ospid} = state) do
    {:noreply, %{state | stderr: [stderr | state.stderr]}}
  end

  def handle_info({:EXIT, pid, reason}, %Build.Exec{pid: pid} = state) do
    end_time = DateTime.utc_now()

    status =
      if reason == :normal do
        :ok
      else
        :error
      end

    # Parse the store path from stdout (nix-build prints it on success)
    store_path =
      state.stdout
      |> Enum.reverse()
      |> Enum.join()
      |> String.trim()

    build = %{
      state.build
      | errors: finalize_output(state.stderr),
        end_time: end_time,
        status: status,
        store_path: if(store_path != "", do: store_path, else: nil)
    }

    log = [
      msg: "Build complete",
      store_path: build.store_path,
      reason: reason,
      status: status
    ]

    if status == :ok do
      Logger.debug(log)
    else
      Logger.warning(log ++ [stderr: state.stderr])
    end

    GenServer.reply(state.from, {status, build})
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.warning(msg: "Unexpected message in Build GenServer", message: msg)
    {:noreply, state}
  end

  defp finalize_output(output) when is_list(output) do
    output
    |> Enum.reverse()
    |> Enum.join()
    |> String.split("\n", trim: true)
  end

  defp finalize_output(output), do: output
end
