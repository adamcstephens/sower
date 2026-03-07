defmodule SowerAgent.Deployer do
  require Logger

  alias SowerAgent.Client
  alias SowerAgent.Config
  alias SowerAgent.Storage
  alias SowerClient.Activator
  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.DeploymentProfile
  alias SowerClient.Orchestration.SeedDeployment
  alias SowerClient.Orchestration.SeedDeploymentResult

  def run(%Deployment{} = deployment) do
    run_with_opts(deployment, upgrade_opts: [], reboot_opts: [])
  end

  def run_with_opts(%Deployment{} = deployment, opts) do
    upgrade_opts = Keyword.get(opts, :upgrade_opts, [])
    reboot_opts = Keyword.get(opts, :reboot_opts, [])

    report_seed_result_fun =
      Keyword.get(upgrade_opts, :report_seed_result_fun, &report_seed_result/4)

    result =
      deployment
      |> upgrade(upgrade_opts)
      |> deployment_result()

    maybe_reboot(deployment, result, [{:report_seed_result_fun, report_seed_result_fun} | reboot_opts])
    result
  end

  def deployment_result(deploy_result) do
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
    upgrade(deployment, [])
  end

  def upgrade(%Deployment{} = deployment, opts) do
    async_stream_fun = Keyword.get(opts, :async_stream_fun, &async_stream/2)
    realize_seed_fun = Keyword.get(opts, :realize_seed_fun, &realize_seed/1)

    get_deployment_profile_fun =
      Keyword.get(opts, :get_deployment_profile_fun, &get_deployment_profile/1)

    activate_seed_fun = Keyword.get(opts, :activate_seed_fun, &SowerAgent.Seed.activate/2)

    report_seed_result_fun =
      Keyword.get(opts, :report_seed_result_fun, &report_seed_result/4)

    async_stream_fun.(deployment.seed_deployments, fn %{seed: seed} = seed_deploy ->
      Logger.debug(
        msg: "Realizing seed",
        name: seed.name,
        seed_sid: seed.sid,
        seed_type: seed.seed_type,
        artifact: seed.artifact
      )

      realize_seed_fun.(seed_deploy)
    end)
    |> async_stream_fun.(fn
      {:ok, {:ok, %SeedDeployment{seed: seed} = seed_deploy}} ->
        profile = get_deployment_profile_fun.(seed_deploy.subscription_sid)
        mode = SowerAgent.Seed.activation_mode(profile)

        preamble = [
          decision_line("realized #{seed.name} (#{seed.seed_type})"),
          decision_line("activating #{seed.name} (#{seed.seed_type}) with mode: #{mode}")
        ]

        Logger.info(
          msg: "Activating seed",
          name: seed.name,
          seed_sid: seed.sid,
          seed_type: seed.seed_type,
          artifact: seed.artifact,
          deployment_sid: deployment.sid,
          activation_args: get_in(profile.activation_args)
        )

        result = activate_seed_fun.(seed, profile)

        case result do
          {:ok, output} ->
            Logger.info(
              msg: "Completed activation",
              deployment_sid: deployment.sid,
              seed_sid: seed.sid
            )

            report_seed_result_fun.(deployment, seed, :success, preamble ++ output)

          {:error, _code, output} ->
            Logger.error(
              msg: "Error during activation",
              deployment_sid: deployment.sid,
              seed_sid: seed.sid
            )

            report_seed_result_fun.(deployment, seed, :failure, preamble ++ output)

          {:error, reason} when reason in [:activator_unavailable, :cmd_not_found] ->
            Logger.error(
              msg: "Missing activator during deployment activation",
              deployment_sid: deployment.sid,
              seed_sid: seed.sid,
              reason: inspect(reason)
            )

            report_seed_result_fun.(
              deployment,
              seed,
              :failure,
              preamble ++
                [
                  "FATAL: missing activator executable sower-activator; deployment cannot continue"
                ]
            )

          {:error, _reason} ->
            :ok
        end

        result

      {:ok, {:error, :failed_to_realize, %SeedDeployment{seed: seed} = _seed_deploy}} ->
        report_seed_result_fun.(deployment, seed, :failure, [
          decision_line("realization failed for #{seed.name} (#{seed.seed_type})")
        ])

        {:error, :failed_to_realize, seed}

      {:ok, {:error, _, _} = error} ->
        error

      {:exit, error} ->
        error
    end)
    |> Enum.to_list()
  end

  defp realize_seed(%SeedDeployment{seed: seed} = seed_deploy) do
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
  end

  def async_stream(enumerable, func) do
    Task.Supervisor.async_stream_nolink(SowerAgent.TaskSupervisor, enumerable, func,
      max_concurrency: 3,
      # 5 minutes
      timeout: 5 * 60_000
    )
  end

  def get_deployment_profile(nil), do: nil

  def get_deployment_profile(
        subscription_sid,
        find_sub \\ &find_subscription/1,
        find_profile \\ &find_deployment_profile/1
      ) do
    case find_sub.(subscription_sid) do
      nil ->
        Logger.info(
          msg: "Subscription not found, using defaults",
          deploy_subscription_sid: subscription_sid
        )

        %DeploymentProfile{}

      sub ->
        profile_name =
          case get_in(sub.deployment_profile) do
            nil ->
              default_profile_name = default_deployment_profile()

              Logger.info(
                msg: "Subscription deployment profile not found, using default",
                default_deployment_profile: default_profile_name,
                deploy_subscription_sid: subscription_sid,
                subscription_seed_name: get_in(sub.seed_name),
                subscription_seed_type: get_in(sub.seed_type)
              )

              default_profile_name

            configured_profile_name ->
              configured_profile_name
          end

        subscription_overrides = find_profile.(profile_name) || %DeploymentProfile{}

        %DeploymentProfile{}
        |> Map.merge(subscription_overrides)
    end
  end

  defp default_deployment_profile() do
    Config.get()
    |> Kernel.||(%{})
    |> Map.get(:default_deployment_profile)
    |> Kernel.||("default")
  end

  def find_deployment_profile(name) do
    config = Config.get()
    get_in(config.deployment_profiles[name]) || %DeploymentProfile{}
  end

  defp find_subscription(sid) do
    Storage.read().subscriptions |> Enum.find(&(&1.sid == sid))
  end

  def maybe_reboot(%Deployment{} = deployment, result) do
    maybe_reboot(deployment, result, [])
  end

  def maybe_reboot(%Deployment{} = deployment, result, opts) when result != :success do
    Logger.debug(msg: "Skipping reboot due to unsuccesful deployment", result: result)
    write_reboot_decision(deployment, opts, "reboot skipped: deployment result was #{result}")
    :ok
  end

  def maybe_reboot(%Deployment{} = deployment, :success, opts) do
    reboot_reason_fun = Keyword.get(opts, :reboot_reason_fun, &reboot_reason/1)
    reboot_fun = Keyword.get(opts, :reboot_fun, &Activator.reboot/1)

    activation_enabled_fun =
      Keyword.get(opts, :activation_enabled_fun, fn ->
        Application.get_env(:sower_agent, :enable_activation, true)
      end)

    if Enum.any?(deployment.seed_deployments, &(get_in(&1.seed.seed_type) == "nixos")) do
      case reboot_reason_fun.(deployment.seed_deployments) do
        nil ->
          write_reboot_decision(deployment, opts, "no reboot required")
          :ok

        reason ->
          if activation_enabled_fun.() do
            Logger.info(
              msg: "Reboot required by deployment policy",
              deployment_sid: deployment.sid,
              reason: reason
            )

            write_reboot_decision(deployment, opts, "reboot initiated: #{reason}")

            case reboot_fun.(reason: reason) do
              {:ok, output} ->
                Logger.info(
                  msg: "Reboot request completed",
                  deployment_sid: deployment.sid,
                  reason: reason,
                  output: output
                )

              {:error, code, output} ->
                Logger.error(
                  msg: "Reboot request failed",
                  deployment_sid: deployment.sid,
                  reason: reason,
                  code: code,
                  output: output
                )

              {:error, reboot_error} ->
                Logger.error(
                  msg: "Reboot request failed",
                  deployment_sid: deployment.sid,
                  reason: reason,
                  error: inspect(reboot_error)
                )
            end
          else
            Logger.debug(
              msg: "Reboot run in noop",
              deployment_sid: deployment.sid,
              reason: reason
            )
          end
      end
    else
      Logger.debug(
        msg: "Skipping reboot for non-nixos deployment",
        deployment_sid: deployment.sid
      )

      :ok
    end
  end

  defp write_reboot_decision(%Deployment{} = deployment, opts, message) do
    report_seed_result_fun =
      Keyword.get(opts, :report_seed_result_fun, &report_seed_result/4)

    last_seed =
      deployment.seed_deployments
      |> Enum.map(& &1.seed)
      |> List.last()

    if last_seed do
      report_seed_result_fun.(deployment, last_seed, nil, [decision_line(message)])
    end
  end

  def reboot_reason(
        seed_deployments,
        get_profile \\ &get_deployment_profile/1,
        read_link \\ &:file.read_link_all/1
      ) do
    profiles =
      seed_deployments
      |> Enum.filter(&(get_in(&1.seed.seed_type) == "nixos"))
      |> Enum.map(fn %SeedDeployment{subscription_sid: subscription_sid} ->
        get_profile.(subscription_sid) || %DeploymentProfile{}
      end)

    cond do
      profiles == [] ->
        nil

      Enum.any?(profiles, fn profile ->
        profile.reboot_policy == "always"
      end) ->
        "policy_always"

      Enum.any?(profiles, fn profile ->
        profile.reboot_policy == "when-required" and
          SowerAgent.Seed.activation_mode(profile) == "boot" and
            not is_nil(detect_boot_critical_change_reason(read_link))
      end) ->
        "boot_mode"

      Enum.any?(profiles, fn profile ->
        profile.reboot_policy == "when-required" and
            SowerAgent.Seed.activation_mode(profile) == "switch"
      end) ->
        detect_boot_critical_change_reason(read_link)

      true ->
        nil
    end
  end

  defp report_seed_result(%Deployment{} = deployment, seed, result, output_lines) do
    log =
      output_lines
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&strip_ansi/1)
      |> Enum.join("\n")

    seed_result =
      SeedDeploymentResult.cast!(%{
        deployment_sid: deployment.sid,
        seed_sid: seed.sid,
        result: result,
        log: log
      })

    case Client.call(SeedDeploymentResult.event(), seed_result, 15_000) do
      :ok ->
        :ok

      {:ok, _reply} ->
        :ok

      {:error, error} ->
        Logger.error(
          msg: "Failed to report seed deployment result",
          deployment_sid: deployment.sid,
          seed_sid: seed.sid,
          result: result,
          error: inspect(error)
        )
    end
  end

  def decision_line(message), do: "[sower] #{message}"

  defp strip_ansi(text) do
    Regex.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, text, "")
  end

  def detect_boot_critical_change_reason(read_link \\ &:file.read_link/1) do
    with {:ok, profile_store_path} <- resolved_symlink("/nix/var/nix/profiles/system", read_link),
         {:ok, current_store_path} <- resolved_symlink("/run/current-system", read_link),
         {:ok, booted_store_path} <- resolved_symlink("/run/booted-system", read_link) do
      cond do
        current_store_path != profile_store_path ->
          "system_changed"

        "#{current_store_path}/initrd" != "#{booted_store_path}/initrd" ->
          "initrd_changed"

        "#{current_store_path}/kernel" != "#{booted_store_path}/kernel" ->
          "kernel_changed"

        "#{current_store_path}/kernel-modules" != "#{booted_store_path}/kernel-modules" ->
          "modules_changed"

        true ->
          nil
      end
    else
      {:error, reason} ->
        Logger.warning(
          msg: "Could not evaluate reboot requirement from system profile links",
          reason: inspect(reason)
        )

        nil
    end
  end

  defp resolved_symlink(path, read_link) do
    resolve_symlink(path, read_link, MapSet.new())
  end

  defp resolve_symlink(path, read_link, visited) do
    cond do
      String.starts_with?(path, "/nix/store/") ->
        {:ok, path}

      MapSet.member?(visited, path) ->
        {:error, {path, :symlink_loop}}

      MapSet.size(visited) >= 20 ->
        {:error, {path, :symlink_depth_exceeded}}

      true ->
        case read_link.(path) do
          {:ok, resolved} when is_binary(resolved) ->
            resolved
            |> resolve_link_target(path)
            |> resolve_symlink(read_link, MapSet.put(visited, path))

          {:ok, resolved} when is_list(resolved) ->
            resolved
            |> List.to_string()
            |> resolve_link_target(path)
            |> resolve_symlink(read_link, MapSet.put(visited, path))

          {:error, :einval} ->
            {:ok, path}

          {:error, reason} ->
            {:error, {path, reason}}

          other ->
            {:error, {path, other}}
        end
    end
  end

  defp resolve_link_target(resolved, path) do
    if Path.type(resolved) == :absolute do
      Path.expand(resolved)
    else
      Path.expand(resolved, Path.dirname(path))
    end
  end
end
