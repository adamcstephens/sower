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
    field :request, Nix.Eval.Request.t()
    field :flags, map()
    field :options, map()
    field :evals, [Nix.Eval.t()]
    field :builds, [Nix.Build.t()]
    field :status, :ok | :error, default: :ok
  end

  def run(target, flags, options) do
    steps = build_steps(flags)
    request_opts = options |> Map.to_list() |> Keyword.take([:attr, :type])
    request = Nix.Eval.Request.parse(target, request_opts)

    state = %__MODULE__{
      request: request,
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
      :push in steps and effective_cache_urls(options) == [] ->
        Output.error("--cache is required for --push")
        {:error, :missing_cache}

      :seed in steps ->
        Application.ensure_all_started([:req])
        SowerCli.Auth.verify_connection()

      true ->
        :ok
    end
  end

  defp effective_cache_urls(options) do
    cli_caches = options.cache || []
    config_caches = SowerCli.Config.get().caches || []

    (cli_caches ++ config_caches)
    |> Enum.uniq()
  end

  defp run_steps([], %__MODULE__{} = state) do
    Output.success("Done")
    {state.status, state}
  end

  defp run_steps([:eval | rest], %__MODULE__{} = state) do
    Output.step("Evaluating #{state.request.path}")

    Output.init(debug: state.flags.debug)

    opts = [
      workers: state.options.eval_jobs,
      type: state.options.eval_type,
      use_eval_cache: state.flags.use_eval_cache,
      memory_limit_kb: state.options.memory_limit * 1_000,
      notify_pid: self()
    ]

    task = Task.async(fn -> Nix.Eval.Jobs.run(state.request, opts) end)

    result =
      receive_progress(task, %{}, fn msg, blocks ->
        case msg do
          {:eval_started, attr} ->
            name = attr || "(root)"
            block_id = {:eval, name}
            Output.live_item_start(block_id, "Evaluating", name)
            Map.put(blocks, name, block_id)

          {:eval_completed, attr, status} ->
            name = attr || "(root)"
            block_id = Map.get(blocks, name, {:eval, name})

            case status do
              :ok -> Output.live_item_done(block_id, "Evaluated", name)
              :branch -> Output.live_item_done(block_id, "Discovered", name)
              _ -> Output.live_item_error(block_id, "Eval failed", name)
            end

            blocks
        end
      end)

    Output.live_flush()

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
            run_steps(rest, %{state | evals: successful, status: :error})
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
      receive_progress(task, %{}, fn msg, blocks ->
        case msg do
          {:build_started, attr} ->
            name = attr || "(unknown)"
            block_id = {:build, name}
            Output.live_item_start(block_id, "Building", name)
            Map.put(blocks, name, block_id)

          {:build_completed, attr, status} ->
            name = attr || "(unknown)"
            block_id = Map.get(blocks, name, {:build, name})

            case status do
              :ok -> Output.live_item_done(block_id, "Built", name)
              _ -> Output.live_item_error(block_id, "Build failed", name)
            end

            blocks
        end
      end)

    Output.live_flush()

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
            run_steps(rest, %{state | builds: successful, status: :error})
          end
        end
    end
  end

  defp run_steps([:push | rest], %__MODULE__{} = state) do
    builds =
      state.builds
      |> Enum.filter(&(&1.status == :ok))

    cache_urls = effective_cache_urls(state.options)

    Output.step("Pushing #{length(builds)} path(s) to #{length(cache_urls)} cache(s)")

    store_paths =
      builds
      |> Enum.map(& &1.store_path)
      |> Enum.reject(&is_nil/1)

    if length(store_paths) == 0 do
      Output.info("No paths to push")
      run_steps(rest, state)
    else
      results =
        Enum.reduce_while(cache_urls, [], fn cache_url, acc ->
          {:ok, {cache_module, cache_config}} = Cache.parse_url(cache_url)
          result = cache_module.upload(store_paths, cache_config)
          Output.push_summary(cache_url, result)

          case {result, state.flags.fail_fast} do
            {{:error, _}, true} -> {:halt, [{cache_url, result} | acc]}
            _ -> {:cont, [{cache_url, result} | acc]}
          end
        end)
        |> Enum.reverse()

      {successes, failures} =
        Enum.split_with(results, fn {_url, r} -> match?({:ok, _}, r) end)

      cond do
        failures != [] and state.flags.fail_fast ->
          {:error, :push_failed}

        successes == [] ->
          {:error, :push_failed}

        true ->
          builds = Enum.map(builds, fn build -> %{build | cached: true} end)
          new_status = if failures == [], do: state.status, else: :error
          run_steps(rest, %{state | builds: builds, status: new_status})
      end
    end
  end

  defp run_steps([:seed | rest], %__MODULE__{} = state) do
    Application.ensure_all_started([:req])

    client = SowerClient.ApiClient.new()

    repo_tags = SowerCli.Repo.get_tags(state.request)

    results = register_seeds(state, client, repo_tags)

    if Enum.any?(results, &match?({:error, _}, &1)) do
      if state.flags.fail_fast do
        {:error, :seed_failed}
      else
        run_steps(rest, %{state | status: :error})
      end
    else
      run_steps(rest, state)
    end
  end

  def register_seeds(%__MODULE__{} = state, %Req.Request{} = client, repo_tags) do
    Output.step("Registering seeds")

    results =
      state
      |> seed_candidates(repo_tags)
      |> Enum.with_index()
      |> Enum.map(fn
        {{:ok, seed}, idx} ->
          block_id = {:seed, idx}
          Output.live_item_start(block_id, "Registering", seed.name)

          case SowerClient.Seed.create(client, seed, rename: !state.flags.non_authoritative) do
            {:ok, _} = result ->
              Output.live_item_done(block_id, "Registered", seed.name)
              result

            {:error, reason} = error ->
              Output.live_item_error(block_id, "Failed", seed.name)
              Output.error("Failed to register seed: #{inspect(reason)}")
              error
          end

        {{:error, reason} = error, idx} ->
          Output.live_item_error({:seed, idx}, "Failed", "seed manifest")
          Output.error("Failed to prepare seed: #{inspect(reason)}")
          error

        {:skip, _idx} ->
          :skip
      end)

    Output.live_flush()

    results
  end

  def seed_candidates(%__MODULE__{} = state, repo_tags) do
    Enum.map(state.builds, fn %Nix.Build{} = build ->
      if seed_job?(build.eval.request.attr) do
        with {:ok, json} <- File.read(Path.join(build.store_path, "seed.json")),
             {:ok, payload} <- Jason.decode(json),
             {:ok, manifest} <- SowerClient.SeedManifest.cast(payload) do
          seed_from_manifest(manifest, state, repo_tags)
        else
          {:error, reason} -> {:error, {:manifest_failed, reason}}
        end
      else
        :skip
      end
    end)
  end

  defp seed_job?(attr) when is_binary(attr) do
    # Match components without treating dots inside quoted names as path separators.
    Regex.match?(
      ~r{^(?:(?:[^/"]+|"(?:[^"\\]|\\.)*")\.)*(?:(?:nixos|home|seed)/.+|"(?:nixos|home|seed)/(?:[^"\\]|\\.)+")$},
      attr
    )
  end

  defp seed_job?(nil), do: false

  defp seed_from_manifest(
         %SowerClient.SeedManifest{} = manifest,
         %__MODULE__{} = state,
         repo_tags
       ) do
    manifest_tags =
      Enum.map(manifest.tags, fn {key, value} ->
        %SowerClient.SeedTag{key: key, value: value}
      end)

    attrs = %{
      "name" => manifest.name,
      "seed_type" => manifest.seed_type,
      "artifact" => manifest.artifact,
      "tags" => cli_tags(state) ++ manifest_tags ++ repo_tags
    }

    case SowerClient.Seed.cast(attrs) do
      {:ok, seed} -> {:ok, seed}
      {:error, reason} -> {:error, {:cast_failed, reason}}
    end
  end

  defp cli_tags(%__MODULE__{} = state) do
    state.options.tag
    |> Enum.map(&SowerClient.SeedTag.from_string/1)
  end

  defp receive_progress(task, blocks, handler) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:error, {:task_crashed, reason}}

      msg ->
        blocks = handler.(msg, blocks)
        receive_progress(task, blocks, handler)
    end
  end
end
