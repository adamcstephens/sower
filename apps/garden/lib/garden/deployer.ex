defmodule Garden.Deployer do
  require Logger

  alias Garden.Socket

  alias Garden.Storage
  alias SowerClient.Activator
  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.SeedDeployment
  alias SowerClient.Orchestration.SeedDeploymentResult
  alias SowerClient.Orchestration.SeedDeploymentStatus
  alias SowerClient.Orchestration.Subscription
  alias SowerClient.Orchestration.Subscription.Policy

  @rebootable_seed_types ["nixos"]

  def run(%Deployment{} = deployment) do
    run_with_opts(deployment, upgrade_opts: [], reboot_opts: [])
  end

  def run_with_opts(%Deployment{} = deployment, opts) do
    upgrade_opts = Keyword.get(opts, :upgrade_opts, [])
    reboot_opts = Keyword.get(opts, :reboot_opts, [])

    report_seed_result_fun =
      Keyword.get(upgrade_opts, :report_seed_result_fun, &report_seed_result/4)

    upgrades = upgrade_with_actions(deployment, upgrade_opts)
    result = upgrades |> deployment_results() |> deployment_result()

    direct_restart? =
      Enum.any?(upgrades, fn
        {:ok, {:resolved_action, {:ok, _}, :restart}} -> true
        _ -> false
      end)

    reboot_opts = Keyword.put(reboot_opts, :direct_restart?, direct_restart?)

    maybe_reboot(deployment, result, [
      {:report_seed_result_fun, report_seed_result_fun} | reboot_opts
    ])

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
    deployment
    |> upgrade_with_actions(opts)
    |> deployment_results()
  end

  defp deployment_results(upgrades) do
    Enum.map(upgrades, fn
      {:ok, {:resolved_action, result, _action}} -> {:ok, result}
      result -> result
    end)
  end

  defp upgrade_with_actions(%Deployment{} = deployment, opts) do
    async_stream_fun = Keyword.get(opts, :async_stream_fun, &async_stream/2)
    realize_seed_fun = Keyword.get(opts, :realize_seed_fun, &realize_seed/1)

    find_subscription_fun =
      Keyword.get(opts, :find_subscription_fun, &find_subscription/1)

    activate_seed_fun = Keyword.get(opts, :activate_seed_fun, &Garden.Seed.activate/2)

    report_seed_result_fun =
      Keyword.get(opts, :report_seed_result_fun, &report_seed_result/4)

    report_seed_status_fun =
      Keyword.get(opts, :report_seed_status_fun, &report_seed_status/3)

    garden_config_fun = Keyword.get(opts, :garden_config_fun, &Garden.Config.get/0)

    async_stream_fun.(deployment.seed_deployments, fn %{seed: seed} = seed_deploy ->
      Logger.debug(
        msg: "Realizing seed",
        name: seed.name,
        seed_sid: seed.sid,
        seed_type: seed.seed_type,
        artifact: seed.artifact
      )

      downloading_line = decision_line("downloading #{seed.name} (#{seed.seed_type})")
      report_seed_status_fun.(deployment, seed, :downloading)
      {downloading_line, realize_seed_fun.(seed_deploy)}
    end)
    |> async_stream_fun.(fn
      {:ok, {downloading_line, {:ok, %SeedDeployment{seed: seed} = seed_deploy, download_output}}} ->
        subscription = find_subscription_fun.(seed_deploy.subscription_sid) || %Subscription{}

        preamble =
          [downloading_line | download_output] ++
            [decision_line("realized #{seed.name} (#{seed.seed_type})")]

        with action when is_atom(action) <-
               resolve_action(seed_deploy, subscription, garden_config_fun) do
          mode = action_to_mode(action, seed.seed_type)

          result =
            if mode == nil do
              Logger.info(
                msg: "Stage only — skipping activation",
                name: seed.name,
                seed_sid: seed.sid,
                deployment_sid: deployment.sid
              )

              preamble =
                preamble ++
                  [
                    decision_line(
                      "staged #{seed.name} (#{seed.seed_type}), activation not permitted"
                    )
                  ]

              report_seed_status_fun.(deployment, seed, :completed)
              report_seed_result_fun.(deployment, seed, :success, preamble)
              {:ok, ["staged"]}
            else
              preamble =
                preamble ++
                  [
                    decision_line(
                      "activating #{seed.name} (#{seed.seed_type}) with mode: #{mode}"
                    )
                  ]

              Logger.info(
                msg: "Activating seed",
                name: seed.name,
                seed_sid: seed.sid,
                seed_type: seed.seed_type,
                artifact: seed.artifact,
                deployment_sid: deployment.sid,
                mode: mode
              )

              report_seed_status_fun.(deployment, seed, :activating)
              result = activate_seed_fun.(seed, mode)

              case result do
                {:ok, output} ->
                  Logger.info(
                    msg: "Completed activation",
                    deployment_sid: deployment.sid,
                    seed_sid: seed.sid
                  )

                  report_seed_status_fun.(deployment, seed, :completed)
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
            end

          direct_action =
            if seed_deploy.action != nil and seed.seed_type in @rebootable_seed_types, do: action

          {:resolved_action, result, direct_action}
        else
          {:error, :unsupported_action} = error ->
            report_seed_result_fun.(
              deployment,
              seed,
              :failure,
              preamble ++
                [
                  decision_line(
                    "action #{seed_deploy.action} is not supported for #{seed.seed_type}"
                  )
                ]
            )

            error
        end

      {:ok,
       {downloading_line,
        {:error, :failed_to_realize, %SeedDeployment{seed: seed} = _seed_deploy, download_output}}} ->
        report_seed_result_fun.(
          deployment,
          seed,
          :failure,
          [downloading_line | download_output] ++
            [
              decision_line("realization failed for #{seed.name} (#{seed.seed_type})")
            ]
        )

        {:error, :failed_to_realize, seed}

      {:ok, {_downloading_line, {:error, _, _} = error}} ->
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
      {output, 0} ->
        Logger.info(
          msg: "Successfully realized seed",
          name: seed.name,
          seed_sid: seed.sid,
          seed_type: seed.seed_type,
          artifact: seed.artifact
        )

        {:ok, seed_deploy, filter_realize_output(output)}

      {output, exit_code} ->
        output = filter_realize_output(output)

        Logger.error(
          msg: "Failed to realize seed",
          name: seed.name,
          seed_sid: seed.sid,
          seed_type: seed.seed_type,
          artifact: seed.artifact,
          exit_code: exit_code,
          output: output
        )

        {:error, :failed_to_realize, seed_deploy, output}
    end
  end

  def async_stream(enumerable, func) do
    Task.Supervisor.async_stream_nolink(Garden.TaskSupervisor, enumerable, func,
      max_concurrency: 3,
      # 5 minutes
      timeout: 5 * 60_000
    )
  end

  # Nil actions retain subscription policy. Direct actions are locally clamped
  # unless the server authorized an override of deployment policy.
  defp resolve_action(
         %SeedDeployment{action: nil} = _seed_deploy,
         %Subscription{} = subscription,
         _config_fun
       ) do
    Policy.highest_permitted_action(
      subscription.policy,
      DateTime.utc_now(),
      subscription.seed_type,
      subscription.timezone
    )
  end

  defp resolve_action(
         %SeedDeployment{override: true} = seed_deploy,
         %Subscription{},
         _config_fun
       ) do
    action = to_string(seed_deploy.action)
    supported_actions = Map.get(Policy.actions_by_seed_type(), seed_deploy.seed.seed_type, [])

    if action in supported_actions do
      String.to_existing_atom(action)
    else
      {:error, :unsupported_action}
    end
  end

  defp resolve_action(%SeedDeployment{} = seed_deploy, %Subscription{}, config_fun) do
    config = config_fun.()

    permitted =
      Policy.highest_permitted_action(
        config.policy,
        DateTime.utc_now(),
        seed_deploy.seed.seed_type,
        config.timezone
      )

    # An unclamped nil would fall through to the "switch" default; a wire action
    # the local policy will not honour right now must stage instead.
    Policy.clamp_action(seed_deploy.action, permitted) || :stage
  end

  defp find_subscription(sid) do
    (Storage.read().subscriptions || []) |> Enum.find(&(&1.sid == sid))
  end

  def maybe_reboot(%Deployment{} = deployment, result) do
    maybe_reboot(deployment, result, [])
  end

  def maybe_reboot(%Deployment{} = deployment, _result, _opts)
      when deployment.seed_deployments == [] do
    :ok
  end

  def maybe_reboot(%Deployment{} = deployment, result, opts) do
    has_rebootable_seeds =
      Enum.any?(
        deployment.seed_deployments,
        &(get_in(&1.seed.seed_type) in @rebootable_seed_types)
      )

    if has_rebootable_seeds do
      maybe_reboot_seeds(deployment, result, opts)
    else
      Logger.debug(
        msg: "Skipping reboot for non-rebootable deployment",
        deployment_sid: deployment.sid
      )

      :ok
    end
  end

  defp maybe_reboot_seeds(%Deployment{} = deployment, result, opts) when result != :success do
    Logger.debug(msg: "Skipping reboot due to unsuccesful deployment", result: result)
    write_reboot_decision(deployment, opts, "reboot skipped: deployment result was #{result}")
    :ok
  end

  defp maybe_reboot_seeds(%Deployment{} = deployment, :success, opts) do
    reboot_reason_fun =
      Keyword.get(opts, :reboot_reason_fun, fn seeds -> compute_reboot_reason(seeds, opts) end)

    reboot_fun = Keyword.get(opts, :reboot_fun, &Activator.reboot/1)

    activation_enabled_fun =
      Keyword.get(opts, :activation_enabled_fun, fn ->
        Application.get_env(:garden, :enable_activation, true)
      end)

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

  defp compute_reboot_reason(seed_deployments, opts) do
    find_sub = Keyword.get(opts, :find_subscription_fun, &find_subscription/1)
    read_link = Keyword.get(opts, :read_link_fun, &:file.read_link_all/1)
    config_fun = Keyword.get(opts, :garden_config_fun, &Garden.Config.get/0)
    now = DateTime.utc_now()

    direct_restart? =
      Keyword.get_lazy(opts, :direct_restart?, fn ->
        Enum.any?(seed_deployments, fn %SeedDeployment{} = seed_deploy ->
          seed_deploy.action != nil and
            get_in(seed_deploy.seed.seed_type) in @rebootable_seed_types and
            resolve_action(seed_deploy, %Subscription{}, config_fun) == :restart
        end)
      end)

    if direct_restart? do
      "direct_restart"
    else
      restart_permitted =
        seed_deployments
        |> Enum.filter(&(get_in(&1.seed.seed_type) in @rebootable_seed_types))
        |> Enum.any?(fn
          %SeedDeployment{action: nil} = seed_deploy ->
            sub = find_sub.(seed_deploy.subscription_sid) || %Subscription{}

            Policy.highest_permitted_action(sub.policy, now, sub.seed_type, sub.timezone) ==
              :restart

          %SeedDeployment{} ->
            false
        end)

      if restart_permitted, do: detect_boot_critical_change_reason(read_link)
    end
  end

  defp action_to_mode(:restart, _seed_type), do: "boot"
  defp action_to_mode(:activate, "service"), do: "restart"
  defp action_to_mode(:activate, _seed_type), do: "switch"
  defp action_to_mode(:stage, _seed_type), do: nil
  defp action_to_mode(nil, _seed_type), do: "switch"

  defp report_seed_status(%Deployment{} = deployment, seed, status) do
    seed_status =
      SeedDeploymentStatus.cast!(%{
        deployment_sid: deployment.sid,
        seed_sid: seed.sid,
        status: status
      })

    Socket.cast(:seed_status, seed_status)
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

    case Socket.call(SeedDeploymentResult.event(), seed_result, 15_000) do
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

  def decision_line(message) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    "#{timestamp} [garden] #{message}"
  end

  defp filter_realize_output(output) do
    Enum.filter(output, fn line ->
      line not in [
        "warning: you did not specify '--add-root'; the result might be removed by the garbage collector"
      ]
    end)
  end

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
