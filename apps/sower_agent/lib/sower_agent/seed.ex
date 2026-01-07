defmodule SowerAgent.Seed do
  alias SowerClient.Seed

  require Logger

  def run_activator(args) when is_list(args) do
    if Application.get_env(:sower_agent, :enable_activation, true) do
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
    else
      {:ok, ["noop"]}
    end
  end

  def activate(%Seed{seed_type: "home-manager"} = seed) do
    run_activator(["-path", seed.artifact, "-type", "home-manager"])
  end

  def activate(%Seed{seed_type: "nixos"} = seed) do
    mode = "switch"
    run_activator(["-path", seed.artifact, "-type", "nixos", "-mode", mode])
  end
end
