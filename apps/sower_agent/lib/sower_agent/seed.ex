defmodule SowerAgent.Seed do
  alias SowerAgent.ActivatorClient
  alias SowerClient.Seed

  require Logger

  @default_socket_path "/run/sower-activator/activator.sock"

  def activate(%Seed{seed_type: "home-manager"} = seed) do
    run_activation("home-manager", seed.artifact)
  end

  def activate(%Seed{seed_type: "nixos"} = seed) do
    run_activation("nixos", seed.artifact, mode: "switch")
  end

  defp run_activation(type, path, opts \\ []) do
    if Application.get_env(:sower_agent, :enable_activation, true) do
      socket_path = Application.get_env(:sower_agent, :activator_socket, @default_socket_path)

      if ActivatorClient.socket_available?(socket_path) do
        run_via_socket(type, path, Keyword.put(opts, :socket_path, socket_path))
      else
        run_via_cli(type, path, opts)
      end
    else
      {:ok, ["noop"]}
    end
  end

  @doc """
  Run activation via Unix socket.
  """
  def run_via_socket(type, path, opts \\ []) do
    on_output = fn line ->
      Logger.debug(activator_output: line)
    end

    opts = Keyword.put_new(opts, :on_output, on_output)

    case ActivatorClient.activate(type, path, opts) do
      {:ok, output} ->
        {:ok, output}

      {:error, {:activation_failed, code, output}} ->
        Logger.error(msg: "Failed to activate via socket", output: output, return_code: code)
        {:error, code}

      {:error, reason} ->
        Logger.error(msg: "Failed to activate via socket", reason: reason)
        {:error, reason}
    end
  end

  @doc """
  Run activation via CLI (sudo sower-activator).

  Falls back to this method when the activator socket is not available.
  """
  def run_via_cli(type, path, opts \\ []) do
    args = build_cli_args(type, path, opts)

    with activator when not is_nil(activator) <- System.find_executable("sower-activator"),
         sudo when not is_nil(sudo) <- System.find_executable("sudo") do
      case System.cmd(sudo, [activator | args],
             into: [],
             lines: 1024,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          Logger.debug(output: output)
          {:ok, output}

        {output, code} ->
          Logger.error(msg: "Failed to activate", output: output, return_code: code)
          {:error, code}
      end
    else
      nil ->
        Logger.error(msg: "Failed to find required executables sudo and sower-activator")
        {:error, :cmd_not_found}
    end
  end

  defp build_cli_args(type, path, opts) do
    args = ["-path", path, "-type", type]

    case Keyword.get(opts, :mode) do
      nil -> args
      mode -> args ++ ["-mode", mode]
    end
  end
end
