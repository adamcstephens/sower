defmodule SowerAgent.Seed do
  alias SowerClient.{Activator, Seed}
  alias SowerClient.Orchestration.DeploymentProfile

  require Logger

  @default_socket_path "/run/sower-activator/activator.sock"

  def activate(seed, profile \\ %DeploymentProfile{})

  def activate(%Seed{seed_type: "home-manager"} = seed, _profile) do
    run_activation("home-manager", seed.artifact)
  end

  def activate(%Seed{seed_type: "nixos"} = seed, %DeploymentProfile{} = profile) do
    run_activation("nixos", seed.artifact, mode: activation_mode(profile))
  end

  # TODO pass these args through to the activator once we validate the store paths it receives
  def activation_mode(%DeploymentProfile{} = profile) do
    case profile.activation_args do
      [mode | _] when is_binary(mode) and mode != "" ->
        mode

      _ ->
        "switch"
    end
  end

  defp run_activation(type, path, opts \\ []) do
    if Application.get_env(:sower_agent, :enable_activation, true) do
      socket_path = Application.get_env(:sower_agent, :activator_socket, @default_socket_path)

      on_output = fn line ->
        Logger.debug(activator_output: line)
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
