defmodule SowerAgent.Seed do
  alias SowerClient.Seed

  require Logger

  def run_activator(args) when is_list(args) do
    if Application.get_env(:sower_agent, :enable_activation, true) do
      case System.cmd(System.find_executable("sower-activator"), args,
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

  def activate(%Seed{seed_type: "home-manager"} = seed) do
    run_activator(["-path", seed.artifact, "-type", "home-manager"])
  end

  def activate(%Seed{seed_type: "nixos"} = seed) do
    mode = "switch"
    run_activator(["-path", seed.artifact, "-type", "nixos", "-mode", mode])
  end
end
