defmodule Nix.Cache.Attic do
  @moduledoc """
  Binary cache backend using Attic.

  Attic is a Nix binary cache server with efficient uploads and built-in
  parallelism. See: https://github.com/zhaofengli/attic

  ## Configuration

      %{
        cache: "server:cache-name",  # Format: "server-name:cache-name"
        jobs: 5                       # Optional: parallel upload jobs (default: 5)
      }

  The server and cache must be configured in `~/.config/attic/config.toml`:

      [cache."server:cache-name"]
      endpoint = "https://cache.example.com"
      token = "your-auth-token"

  ## Example

      config = %{cache: "production:my-cache", jobs: 8}
      {:ok, result} = Nix.Cache.Attic.upload(config, [
        "/nix/store/abc123-foo",
        "/nix/store/xyz789-bar"
      ])
  """

  use Nix.Cache

  require Logger

  @impl Nix.Cache
  def name(), do: "attic"

  @impl Nix.Cache
  def validate_config(%{cache: cache}) when is_binary(cache) and byte_size(cache) > 0 do
    # Validate cache format: "server:cache-name"
    if String.contains?(cache, ":") do
      :ok
    else
      {:error, "cache must be in format 'server:cache-name'"}
    end
  end

  def validate_config(_) do
    {:error, "cache required (format: 'server:cache-name')"}
  end

  @impl Nix.Cache
  def upload(path, config) when not is_list(path), do: upload([path], config)

  def upload(paths, config) when is_list(paths) do
    if length(paths) == 0 do
      {:ok, %{uploaded: [], failed: []}}
    else
      paths = ensure_store_paths(paths)

      %{cache: cache} = config
      jobs = Map.get(config, :jobs, 5)

      attic_cmd = System.find_executable("attic")

      if is_nil(attic_cmd) do
        {:error, "attic command not found in PATH"}
      else
        cmd = [attic_cmd, "push", "--stdin", "-j", to_string(jobs), cache]
        stdin_input = Enum.join(paths, "\n")

        Logger.debug(
          msg: "Uploading to cache",
          backend: "attic",
          cache: cache,
          path_count: length(paths),
          jobs: jobs
        )

        case run_with_stdin(cmd, stdin_input) do
          {:ok, _result} ->
            Logger.info(
              msg: "Upload succeeded",
              backend: "attic",
              cache: cache,
              path_count: length(paths)
            )

            {:ok, %{uploaded: paths, failed: []}}

          {:error, %{exit_status: exit_code} = result} ->
            output = Map.get(result, :stderr, "") <> Map.get(result, :stdout, "")

            Logger.error(
              msg: "Upload failed",
              backend: "attic",
              cache: cache,
              exit_code: exit_code,
              output: String.slice(output, 0, 500)
            )

            error_reason = parse_error(output, exit_code)
            {:error, error_reason}
        end
      end
    end
  end

  defp run_with_stdin(cmd, stdin_data) do
    case Rexec.run(cmd) do
      {:ok, pid, ospid} ->
        :ok = Rexec.send(pid, stdin_data)
        :ok = Rexec.send(pid, :eof)
        await_completion(pid, ospid, [], [])

      {:error, reason} ->
        {:error, %{exit_status: 1, stderr: to_string(reason), stdout: ""}}
    end
  end

  defp await_completion(pid, ospid, stdout, stderr) do
    receive do
      {:stdout, ^ospid, data} ->
        await_completion(pid, ospid, [data | stdout], stderr)

      {:stderr, ^ospid, data} ->
        await_completion(pid, ospid, stdout, [data | stderr])

      {:DOWN, _ospid, :process, _pid, :normal} ->
        {:ok, finalize_output(stdout, stderr)}

      {:DOWN, _ospid, :process, _pid, {:shutdown, {:exit_status, status}}} ->
        {:error, finalize_output(stdout, stderr) |> Map.put(:exit_status, status)}
    after
      # 30 minute timeout for large uploads
      30 * 60 * 1000 ->
        Rexec.kill(pid, :sigterm)
        {:error, %{exit_status: 1, stderr: "timeout", stdout: ""}}
    end
  end

  defp finalize_output(stdout, stderr) do
    %{
      stdout: stdout |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: stderr |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp parse_error(output, exit_code) do
    cond do
      String.contains?(output, "401 Unauthorized") or
          String.contains?(output, "permission denied") ->
        "authentication failed - check token in attic config"

      String.contains?(output, "404 Not Found") ->
        "cache not found"

      String.contains?(output, "Connection refused") or
          String.contains?(output, "failed to connect") ->
        "connection refused - check cache endpoint"

      String.contains?(output, "No cache named") ->
        "cache not configured in ~/.config/attic/config.toml"

      true ->
        # Return exit code and first line of output
        first_line =
          output
          |> String.split("\n", parts: 2)
          |> List.first()
          |> String.slice(0, 200)

        {exit_code, first_line}
    end
  end
end
