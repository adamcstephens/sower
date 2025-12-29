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

    opts = [
      workers: state.options.jobs,
      type: state.options.eval_type,
      use_eval_cache: state.flags.use_eval_cache
    ]

    case Nix.Eval.Jobs.run(state.flake, opts) do
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

    workers = state.options.jobs || 4

    case Nix.Build.Jobs.run(state.evals, max_workers: workers) do
      {:ok, result} ->
        builds = Output.build_summary(result)
        run_steps(rest, %{state | builds: builds})

      {:error, result} ->
        builds = Output.build_summary(result)
        Output.build_errors(builds)

        if state.flags.fail_fast do
          {:error, :build_failed}
        else
          if not Enum.all?(builds, &(&1.status == :ok)) do
            {:error, :build_failed}
          else
            run_steps(rest, %{state | builds: builds})
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

    load_tags(state)
    |> dbg()

    run_steps(rest, state)
  end

  defp load_tags(%__MODULE__{} = state) do
    state.options.tag
    |> Enum.map(&SowerClient.Schemas.SeedTag.from_string/1)
    |> add_env_tags()
  end

  defp add_env_tags(tags) do
    [
      tag_git_branch()
      | tags
    ]
  end

  defp tag_git_branch() do
    # TODO put something real here
    %SowerClient.Schemas.SeedTag{key: "git_branch", value: "main"}
  end
end
