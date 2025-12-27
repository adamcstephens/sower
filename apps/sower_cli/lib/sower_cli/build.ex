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
    field :options, map()
    field :evals, [Nix.Eval.t()]
    field :builds, [Nix.Build.t()]
    field :cache_module, module()
    field :cache_config, map()
  end

  @doc """
  Run the build pipeline based on flags.

  ## Options
  - `:cache` - Cache URL (required for push/seed)
  - `:jobs` - Number of parallel workers
  - `:tag` - Metadata tags (for seed)
  - `:fail_fast` - Exit immediately if any step fails (default: false, continue with successful items)
  """
  def run(flake, flags, options) do
    steps = build_steps(flags)

    options = Map.put(options, :fail_fast, flags[:fail_fast] || false)

    state = %__MODULE__{
      flake: flake,
      options: options
    }

    case validate_options(steps, options) do
      :ok ->
        run_steps(steps, state)

      {:error, _} = error ->
        error
    end
  end

  defp build_steps(%{eval_only: true}), do: [:eval]
  defp build_steps(%{push: true}), do: [:eval, :build, :push]
  defp build_steps(%{seed: true}), do: [:eval, :build, :push, :seed]
  defp build_steps(_), do: [:eval, :build]

  defp validate_options(steps, options) do
    cond do
      :push in steps and is_nil(options.cache) ->
        Output.error("--cache is required for --push")
        {:error, :missing_cache}

      :seed in steps and is_nil(options.cache) ->
        Output.error("--cache is required for --seed")
        {:error, :missing_cache}

      not is_nil(options.cache) ->
        case Cache.parse_url(options.cache) do
          {:ok, _} -> :ok
          {:error, msg} -> Output.error(msg) && {:error, :invalid_cache}
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

    workers = state.options.jobs || 8
    eval_type = state.options.type || :auto

    opts = [workers: workers, type: eval_type]

    case Nix.Eval.Jobs.run(state.flake, opts) do
      {:ok, %{results: results}} ->
        Output.eval_summary(results)
        run_steps(rest, %{state | evals: results})

      {:error, %{results: results}} ->
        Output.eval_summary(results)
        Output.eval_errors(results)

        if state.options.fail_fast do
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

        if state.options.fail_fast do
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

    {:ok, {cache_module, cache_config}} = Cache.parse_url(state.options.cache)

    store_paths =
      state.builds
      |> Enum.filter(&(&1.status == :ok))
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
          run_steps(rest, %{state | cache_module: cache_module, cache_config: cache_config})

        {:error, _reason} ->
          {:error, :push_failed}
      end
    end
  end

  defp run_steps([:seed | rest], %__MODULE__{} = state) do
    Output.step("Registering seed")
    Output.info("TODO: seed registration not yet implemented")

    # Show what would be registered
    if state.options.tag do
      Output.info("Tags: #{inspect(state.options.tag)}")
    end

    run_steps(rest, state)
  end
end
