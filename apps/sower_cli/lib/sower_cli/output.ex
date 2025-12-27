defmodule SowerCli.Output do
  @moduledoc """
  Terminal output formatting for CLI feedback.
  """

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
  def error(message) do
    IO.puts("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{message}")
  end

  @doc """
  Print an info message.
  """
  def info(message) do
    IO.puts("  #{message}")
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
  Print push results summary.
  """
  def push_summary({:ok, %{uploaded: uploaded, failed: failed}}) do
    if length(failed) == 0 do
      success("Pushed #{length(uploaded)} path(s) to cache")
    else
      error("Pushed #{length(uploaded)} path(s), #{length(failed)} failed")
    end
  end

  def push_summary({:error, reason}) do
    error("Push failed: #{inspect(reason)}")
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
      reason = format_eval_error(eval)
      error("#{attr}: #{reason}")
    end)
  end

  defp format_eval_error(%Nix.Eval{status: :memory_limit_exceeded} = eval) do
    peak_mb = eval.mem_samples |> Enum.max(fn -> 0 end) |> Kernel./(1024) |> Float.round(1)
    limit_mb = (eval.memory_limit_kb / 1024) |> Float.round(1)
    "memory limit exceeded (peak: #{peak_mb} MB, limit: #{limit_mb} MB)"
  end

  defp format_eval_error(%Nix.Eval{errors: errors}) do
    Enum.join(errors, ", ")
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
      |> Enum.take(-10)
      |> Enum.each(&info/1)
    end)
  end
end
