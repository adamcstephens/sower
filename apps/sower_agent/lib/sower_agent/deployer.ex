defmodule SowerAgent.Deployer do
  require Logger

  alias SowerClient.Orchestration.Deployment

  def run(%Deployment{} = deployment) do
    deploy_result = upgrade(deployment)

    Enum.all?(deploy_result, fn r ->
      case r do
        {:ok, {:ok, _}} -> true
        _ -> false
      end
    end)
    |> case do
      true ->
        :success

      false ->
        Enum.any?(deploy_result, fn r ->
          case r do
            {:ok, {:ok, _}} -> true
            _ -> false
          end
        end)
        |> case do
          true -> :partial
          false -> :failure
        end
    end
  end

  def upgrade(%Deployment{} = deployment) do
    deployment.seeds
    |> async_stream(fn seed ->
      Logger.debug(
        msg: "Realizing seed",
        name: seed.name,
        seed_sid: seed.sid,
        seed_type: seed.seed_type,
        artifact: seed.artifact
      )

      case System.cmd("nix-store", ["--realize", seed.artifact],
             stderr_to_stdout: true,
             into: [],
             lines: 1024
           ) do
        {_output, 0} ->
          Logger.info(
            msg: "Successfully realized seed",
            name: seed.name,
            seed_sid: seed.sid,
            seed_type: seed.seed_type,
            artifact: seed.artifact
          )

          {:ok, seed}

        {output, exit_code} ->
          output =
            Enum.filter(output, fn line ->
              line not in [
                "warning: you did not specify '--add-root'; the result might be removed by the garbage collector"
              ]
            end)

          Logger.error(
            msg: "Failed to realize seed",
            name: seed.name,
            seed_sid: seed.sid,
            seed_type: seed.seed_type,
            artifact: seed.artifact,
            exit_code: exit_code,
            output: output
          )

          {:error, :failed_to_realize, seed}
      end
    end)
    |> async_stream(fn
      {:ok, {:ok, seed}} ->
        Logger.info(
          msg: "Activating seed",
          name: seed.name,
          seed_sid: seed.sid,
          seed_type: seed.seed_type,
          artifact: seed.artifact
        )

        result = SowerAgent.Seed.activate(seed)

        case result do
          {:ok, output} ->
            maybe_write_log(deployment, seed, output)

          {:error, _code, output} ->
            maybe_write_log(deployment, seed, output)

          {:error, _reason} ->
            :ok
        end

        result

      {:ok, {:error, _, _} = error} ->
        error

      {:exit, error} ->
        error
    end)
    |> Enum.to_list()
  end

  def async_stream(enumerable, func) do
    Task.Supervisor.async_stream_nolink(SowerAgent.TaskSupervisor, enumerable, func,
      max_concurrency: 3,
      # 5 minutes
      timeout: 5 * 60_000
    )
  end

  defp maybe_write_log(_deployment, _seed, []), do: :ok

  # TODO: when you write to disk, you should ensure it gets deleted
  defp maybe_write_log(%Deployment{} = deployment, seed, output_lines) do
    state_dir = SowerAgent.Config.get().state_directory
    deployments_dir = Path.join(state_dir, "deployments")
    File.mkdir_p!(deployments_dir)

    date = DateTime.utc_now() |> DateTime.to_unix()
    filename = "#{date}-#{deployment.sid}-#{seed.sid}.log"
    path = Path.join(deployments_dir, filename)

    cleaned_output = Enum.map(output_lines, &strip_ansi/1)
    content = Enum.join(cleaned_output, "\n")
    File.write!(path, content)

    Logger.debug(msg: "Wrote deployment log", path: path)
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, text, "")
  end
end
