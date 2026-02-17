defmodule SowerCli.Output do
  @moduledoc """
  Terminal output formatting for CLI feedback.
  """

  @doc """
  Initialize output mode. When debug is true, uses simple line-by-line output.
  When false, uses Owl.LiveScreen for in-place updates (if TTY is available).
  """
  def init(opts \\ []) do
    if opts[:debug] or not tty?() do
      Process.put(:output_mode, :simple)
    else
      Application.ensure_all_started(:owl)
      Process.put(:output_mode, :live)
    end
  end

  defp tty? do
    # Check if stdout is a TTY
    case :io.getopts(:standard_io) do
      {:ok, _} ->
        # Also check if we're in a CI environment
        System.get_env("CI") not in ["true", "1"]

      _ ->
        false
    end
  end

  defp live_mode?, do: Process.get(:output_mode, :live) == :live

  @doc """
  Print a step header.
  """
  def step(name) do
    IO.puts("\n#{IO.ANSI.cyan()}#{IO.ANSI.bright()}==> #{name}#{IO.ANSI.reset()}")
  end

  @doc """
  Print a success message.
  """
  def success(message) do
    IO.puts("#{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{message}")
  end

  @doc """
  Print an error message.
  """
  def error(errors) when is_list(errors) do
    errors
    |> Enum.join("\n")
    |> error()
  end

  def error(message) when is_binary(message) do
    IO.puts("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{message}")
  end

  @doc """
  Print an info message.
  """
  def info(message) do
    IO.puts("  #{message}")
  end

  @doc """
  Add a live-updating item block. Returns the block_id for later updates.
  In simple mode, prints start message immediately.
  """
  def live_item_start(block_id, action, name) do
    if live_mode?() do
      Owl.LiveScreen.add_block(block_id,
        state: {action, name, :pending},
        render: &render_item/1
      )

      Owl.LiveScreen.await_render()
    else
      IO.puts("  #{IO.ANSI.yellow()}⋯#{IO.ANSI.reset()} #{action} #{name}")
    end

    block_id
  end

  @doc """
  Update a live item to show completion.
  In simple mode, prints completion message.
  """
  def live_item_done(block_id, action, name) do
    if live_mode?() do
      Owl.LiveScreen.update(block_id, {action, name, :ok})
      Owl.LiveScreen.await_render()
    else
      IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{action} #{name}")
    end
  end

  @doc """
  Update a live item to show error.
  In simple mode, prints error message.
  """
  def live_item_error(block_id, action, name) do
    if live_mode?() do
      Owl.LiveScreen.update(block_id, {action, name, :error})
      Owl.LiveScreen.await_render()
    else
      IO.puts("  #{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{action} #{name}")
    end
  end

  defp render_item({action, name, :pending}) do
    ["  ", Owl.Data.tag("⋯", :yellow), " #{action} #{name}"]
  end

  defp render_item({action, name, :ok}) do
    ["  ", Owl.Data.tag("✓", :green), " #{action} #{name}"]
  end

  defp render_item({action, name, :error}) do
    ["  ", Owl.Data.tag("✗", :red), " #{action} #{name}"]
  end

  @doc """
  Flush all live blocks and render final state.
  No-op in simple mode.
  """
  def live_flush do
    if live_mode?() do
      Owl.LiveScreen.await_render()
      Owl.LiveScreen.flush()
    end
  end

  @doc """
  Print eval results summary.
  """
  def eval_summary(results) do
    total = length(results)
    ok_count = Enum.count(results, &(&1.status == :ok))
    error_count = total - ok_count

    if error_count == 0 do
      success("Evaluated #{total} derivation(s)")
    else
      error("Evaluated #{total} derivation(s): #{ok_count} ok, #{error_count} failed")
    end

    results
  end

  @doc """
  Print build results summary.
  """
  def build_summary(%Nix.Build.Jobs.Result{results: builds}) do
    total = length(builds)
    ok_count = Enum.count(builds, &(&1.status == :ok))
    error_count = total - ok_count

    if error_count == 0 do
      success("Built #{total} derivation(s)")
    else
      error("Built #{total} derivation(s): #{ok_count} ok, #{error_count} failed")
    end

    builds
  end

  @doc """
  Print push results summary for a specific cache.
  """
  def push_summary(cache_url, {:ok, %{uploaded: uploaded, failed: failed}}) do
    if length(failed) == 0 do
      success("Pushed #{length(uploaded)} path(s) to #{cache_url}")
    else
      error("Pushed #{length(uploaded)} path(s) to #{cache_url}, #{length(failed)} failed")
    end
  end

  def push_summary(cache_url, {:error, reason}) do
    error("Push to #{cache_url} failed: #{inspect(reason)}")
  end

  @doc """
  Print a list of store paths.
  """
  def store_paths(paths) do
    Enum.each(paths, fn path ->
      info(path)
    end)
  end

  @doc """
  Print errors from eval results.
  """
  def eval_errors(results) do
    failed = Enum.filter(results, &(&1.status != :ok))

    Enum.each(failed, fn %Nix.Eval{} = eval ->
      attr = eval.request.attr || "(root)"
      error("#{attr}:")
      format_eval_error(eval)
    end)
  end

  defp format_eval_error(%Nix.Eval{status: :memory_limit_exceeded} = eval) do
    peak_mb = eval.mem_samples |> Enum.max(fn -> 0 end) |> Kernel./(1024) |> Float.round(1)
    limit_mb = (eval.memory_limit_kb / 1024) |> Float.round(1)
    info("  memory limit exceeded (peak: #{peak_mb} MB, limit: #{limit_mb} MB)")
  end

  defp format_eval_error(%Nix.Eval{errors: errors}) do
    Enum.each(errors, fn line ->
      info("  #{line}")
    end)
  end

  @doc """
  Print errors from build results.
  """
  def build_errors(builds) do
    failed = Enum.filter(builds, &(&1.status != :ok))

    Enum.each(failed, fn build ->
      path = build.drv_path || "(unknown)"
      error("#{path}")

      build.log
      |> Enum.take(-40)
      |> Enum.each(&info/1)
    end)
  end
end
