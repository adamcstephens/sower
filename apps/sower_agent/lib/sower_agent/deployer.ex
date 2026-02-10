defmodule SowerAgent.Deployer do
  require Logger

  alias SowerAgent.Config
  alias SowerAgent.Storage
  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.DeploymentProfile
  alias SowerClient.Orchestration.SeedDeployment

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
    deployment.seed_deployments
    |> async_stream(fn %{seed: seed} = seed_deploy ->
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

          {:ok, seed_deploy}

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

          {:error, :failed_to_realize, seed_deploy}
      end
    end)
    |> async_stream(fn
      {:ok, {:ok, %SeedDeployment{seed: seed} = seed_deploy}} ->
        Logger.info(
          msg: "Activating seed",
          name: seed.name,
          seed_sid: seed.sid,
          seed_type: seed.seed_type,
          artifact: seed.artifact,
          deployment_sid: deployment.sid
        )

        result = SowerAgent.Seed.activate(seed, get_deploy_profile(seed_deploy.subscription_sid))

        case result do
          {:ok, output} ->
            Logger.info(
              msg: "Completed activation",
              deployment_sid: deployment.sid,
              seed_sid: seed.sid
            )

            maybe_write_log(deployment, seed, output)

          {:error, _code, output} ->
            Logger.error(
              msg: "Error during activation",
              deployment_sid: deployment.sid,
              seed_sid: seed.sid
            )

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

  def get_deploy_profile(nil), do: nil

  def get_deploy_profile(
        subscription_sid,
        find_sub \\ &find_subscription/1,
        find_profile \\ &find_deploy_profile/1
      ) do
    sub = find_sub.(subscription_sid)

    subscription_overrides =
      case get_in(sub.deployment_profile) do
        nil ->
          Logger.warning(
            msg: "Subscription not found, using defaults",
            deploy_subscription_sid: subscription_sid
          )

          %{}

        profile_name ->
          find_profile.(profile_name) || %{}
      end

    %DeploymentProfile{}
    |> Map.merge(subscription_overrides)
  end

  defp find_deploy_profile(name) do
    config = Config.get()
    get_in(config.deploy_profiles[name])
  end

  defp find_subscription(sid) do
    Storage.read().subscriptions |> Enum.find(&(&1.sid == sid))
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
