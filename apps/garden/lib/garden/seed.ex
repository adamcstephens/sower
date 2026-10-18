defmodule Garden.Seed do
  alias SowerClient.{Activator, Seed}

  require Logger

  @default_socket_path "/run/sower-activator/activator.sock"

  def activate(seed, mode \\ "switch", on_output \\ fn _line -> :ok end)

  def activate(%Seed{seed_type: "home-manager"} = seed, _mode, on_output) do
    run_activation("home-manager", seed.artifact, [tags: seed.tags], on_output)
  end

  def activate(%Seed{seed_type: "nixos"} = seed, mode, on_output) do
    run_activation("nixos", seed.artifact, [mode: mode], on_output)
  end

  defp run_activation(type, path, opts, output_fun) do
    if Application.get_env(:garden, :enable_activation, true) do
      socket_path = Application.get_env(:garden, :activator_socket, @default_socket_path)

      on_output = fn line ->
        Logger.debug(activator_output: line)
        output_fun.(line)
      end

      opts =
        opts
        |> Keyword.put(:socket_path, socket_path)
        |> Keyword.put(:on_output, on_output)

      case Activator.activate(type, path, opts) do
        {:ok, output} ->
          {:ok, output}

        {:error, code, output} when is_integer(code) ->
          Logger.error(msg: "Failed to activate", output: output, return_code: code)
          {:error, code, output}

        {:error, reason} ->
          Logger.error(msg: "Failed to activate", reason: reason)
          {:error, reason}
      end
    else
      Logger.debug(msg: "Activation run in noop", type: type, path: path, opts: opts)
      {:ok, ["noop"]}
    end
  end
end
