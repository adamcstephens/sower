defmodule SowerCli.Build do
  @moduledoc """
  Build pipeline orchestration.

  Runs a sequence of steps based on flags:
  - `--eval-only` → [:eval]
  - (default)     → [:eval, :build]
  - `--push`      → [:eval, :build, :push]
  - `--seed`      → [:eval, :build, :push, :seed]
  """

  use TypedStruct

  require Logger

  alias SowerCli.{Cache, Output}

  typedstruct do
    field :flake, String.t()
    field :flags, map()
    field :options, map()
    field :evals, [Nix.Eval.t()]
    field :builds, [Nix.Build.t()]
    field :cache_module, module()
    field :cache_config, map()
  end

  def run(flake, flags, options) do
    steps = build_steps(flags)

    state = %__MODULE__{
      flake: flake,
      options: options,
      flags: flags
    }

    case validate_options(steps, options) do
      :ok ->
        run_steps(steps, state)

      {:error, _} = error ->
        error
    end
  end

  defp build_steps(%{eval_only: true}), do: [:eval]
  defp build_steps(%{seed: true}), do: [:eval, :build, :push, :seed]
  defp build_steps(%{push: true}), do: [:eval, :build, :push]
  defp build_steps(_), do: [:eval, :build]

  defp validate_options(steps, options) do
    cond do
      :push in steps and is_nil(options.cache) ->
        config = SowerCli.Config.get()

        if is_nil(config.cache) do
          Output.error("--cache is required for --push")
          {:error, :missing_cache}
        else
          :ok
        end

      :seed in steps ->
        config = SowerCli.Config.get()

        try do
          SowerCli.Config.require_server_connection!(config)
          :ok
        rescue
          e in ArgumentError ->
            Output.error("#{e.message}")
            {:error, :missing_server_config}
        end

      true ->
        :ok
    end
  end

  defp run_steps([], %__MODULE__{} = state) do
    Output.success("Done")
    {:ok, state}
  end

  defp run_steps([:eval | rest], %__MODULE__{} = state) do
    Output.step("Evaluating #{state.flake}")

    Application.ensure_all_started([:erlexec])

    opts = [
      workers: state.options.eval_jobs,
      type: state.options.eval_type,
      use_eval_cache: state.flags.use_eval_cache,
      memory_limit_kb: state.options.memory_limit * 1_000,
      notify_pid: self()
    ]

    task = Task.async(fn -> Nix.Eval.Jobs.run(state.flake, opts) end)

    result =
      receive_progress(task, fn
        {:eval_started, attr} ->
          Output.item_start("Evaluating", attr || "(root)")

        {:eval_completed, attr, :ok} ->
          Output.item_done("Evaluated", attr || "(root)")

        {:eval_completed, attr, :branch} ->
          Output.item_done("Discovered", attr || "(root)")

        {:eval_completed, attr, _error} ->
          Output.item_error("Eval failed", attr || "(root)")
      end)

    case result do
      {:ok, %{results: results}} ->
        Output.eval_summary(results)
        run_steps(rest, %{state | evals: results})

      {:error, %{results: results}} ->
        Output.eval_summary(results)
        Output.eval_errors(results)

        if state.flags.fail_fast do
          {:error, :eval_failed}
        else
          successful = Enum.filter(results, &(&1.status == :ok))

          if Enum.empty?(successful) do
            {:error, :eval_failed}
          else
            run_steps(rest, %{state | evals: successful})
          end
        end
    end
  end

  defp run_steps([:build | rest], %__MODULE__{} = state) do
    Output.step("Building #{length(state.evals)} derivation(s)")

    opts = [
      max_workers: state.options.build_jobs,
      notify_pid: self()
    ]

    task = Task.async(fn -> Nix.Build.Jobs.run(state.evals, opts) end)

    result =
      receive_progress(task, fn
        {:build_started, drv_path} ->
          Output.item_start("Building", drv_path || "(unknown)")

        {:build_completed, drv_path, :ok} ->
          Output.item_done("Built", drv_path || "(unknown)")

        {:build_completed, drv_path, _error} ->
          Output.item_error("Build failed", drv_path || "(unknown)")
      end)

    case result do
      {:ok, job_result} ->
        builds = Output.build_summary(job_result)
        run_steps(rest, %{state | builds: builds})

      {:error, job_result} ->
        builds = Output.build_summary(job_result)
        Output.build_errors(builds)

        if state.flags.fail_fast do
          {:error, :build_failed}
        else
          successful = Enum.filter(builds, &(&1.status == :ok))

          if Enum.empty?(successful) do
            {:error, :build_failed}
          else
            run_steps(rest, %{state | builds: successful})
          end
        end
    end
  end

  defp run_steps([:push | rest], %__MODULE__{} = state) do
    Output.step("Pushing to cache")

    cache_url = state.options.cache || SowerCli.Config.get().cache
    {:ok, {cache_module, cache_config}} = Cache.parse_url(cache_url)

    builds =
      state.builds
      |> Enum.filter(&(&1.status == :ok))

    store_paths =
      builds
      |> Enum.map(& &1.store_path)
      |> Enum.reject(&is_nil/1)

    if length(store_paths) == 0 do
      Output.info("No paths to push")
      run_steps(rest, state)
    else
      result = cache_module.upload(store_paths, cache_config)
      Output.push_summary(result)

      case result do
        {:ok, _} ->
          # we're batch uploading, so don't get individual results
          # mark all builds as cached
          builds = builds |> Enum.map(fn build -> %{build | cached: true} end)

          run_steps(rest, %{
            state
            | cache_module: cache_module,
              cache_config: cache_config,
              builds: builds
          })

        {:error, _reason} ->
          {:error, :push_failed}
      end
    end
  end

  defp run_steps([:seed | rest], %__MODULE__{} = state) do
    Output.step("Registering seed")

    Application.ensure_all_started([:req])

    client = SowerClient.ApiClient.new()

    results =
      Enum.map(state.builds, fn
        %Nix.Build{
          eval: %Nix.Eval{
            output: %{
              "meta" => %{
                "sower" => %{
                  "seed" => seed_meta
                }
              }
            }
          }
        } = build ->
          seed_name = Map.get(seed_meta, "name", build.store_path)
          Output.item_start("Registering", seed_name)
          tags = load_tags(state) ++ Map.get(seed_meta, "tags", []) ++ SowerCli.Repo.get_tags()

          case seed_meta
               |> Map.put("tags", tags)
               |> Map.put("artifact", build.store_path)
               |> SowerClient.Seed.cast() do
            {:ok, seed} ->
              case SowerClient.Seed.create(client, seed) do
                {:ok, _} = result ->
                  Output.item_done("Registered", seed_name)
                  result

                {:error, reason} = error ->
                  Output.item_error("Failed", seed_name)
                  Output.error("Failed to register seed: #{inspect(reason)}")
                  error
              end

            {:error, error} ->
              Output.item_error("Failed", seed_name)
              Output.error("Failed to cast seed: #{inspect(error)}")
              {:error, {:cast_failed, error}}
          end

        %Nix.Build{eval: eval} ->
          Logger.debug(msg: "Eval is missing sower seed metadata", eval: eval)
          :skip
      end)

    errors =
      results
      |> Enum.filter(fn
        {:error, _} -> true
        _ -> false
      end)

    if Enum.empty?(errors) do
      run_steps(rest, state)
    else
      if state.flags.fail_fast do
        {:error, :seed_failed}
      else
        run_steps(rest, state)
      end
    end
  end

  defp load_tags(%__MODULE__{} = state) do
    state.options.tag
    |> Enum.map(&SowerClient.SeedTag.from_string/1)
  end

  defp receive_progress(task, handler) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:error, {:task_crashed, reason}}

      msg ->
        handler.(msg)
        receive_progress(task, handler)
    end
  end
end
