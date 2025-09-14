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
    end
  end

  def activate(%Seed{seed_type: "nixos"}) do
    # err = setProfile("/nix/var/nix/profiles/system", storePath)
    # switchCmd := exec.Command(fmt.Sprintf("%s/bin/switch-to-configuration", storePath), mode)
    {:error, :TODO}
  end
end
