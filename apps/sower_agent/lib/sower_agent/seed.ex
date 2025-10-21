defmodule SowerAgent.Seed do
  alias SowerClient.Schemas.Seed

  require Logger

  def activate(%Seed{seed_type: "home-manager"} = seed) do
    if Application.get_env(:sower_agent, :enable_activation, false) do
      case System.cmd("#{seed.artifact}/activate", [],
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
      {:ok, ["noop"]}
    end
  end

  def activate(%Seed{seed_type: "nixos"} = seed) do
    {_, 0} =
      maybe_sudo_cmd(
        "nix-env",
        [
          "--set",
          "--profile",
          Nix.NixOS.profile_path(),
          seed.artifact
        ]
      )

    case maybe_sudo_cmd("#{seed.artifact}/bin/switch-to-configuration", ["switch"],
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

    {:error, :TODO}
  end

  defp maybe_sudo_cmd(command, args, opts \\ []) do
    if Application.get_env(:sower_agent, :sudo, false) do
      System.cmd("sudo", [command | args], opts)
    else
      System.cmd(command, args, opts)
    end
  end
end
