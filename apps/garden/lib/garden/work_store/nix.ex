defmodule Garden.WorkStore.Nix do
  @moduledoc false

  def remove_tree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.chmod(path, 0o700),
             {:ok, names} <- File.ls(path),
             :ok <-
               Enum.reduce_while(names, :ok, fn name, :ok ->
                 case remove_tree(Path.join(path, name)) do
                   :ok -> {:cont, :ok}
                   error -> {:halt, error}
                 end
               end) do
          File.rmdir(path)
        end

      {:ok, _} ->
        File.rm(path)

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  # Rexec's completion is a certificate that the entire native tree was reaped.
  # Only bounded command metadata is accumulated; NARs always travel via files.
  def run(options, args) do
    Process.flag(:trap_exit, true)
    executable = Keyword.fetch!(options, :nix)

    command = [
      executable,
      "--extra-experimental-features",
      "nix-command",
      "--store",
      Keyword.fetch!(options, :root),
      "--option",
      "substitute",
      "false",
      "--option",
      "substituters",
      "",
      "--option",
      "require-sigs",
      "true",
      "--option",
      "secret-key-files",
      "",
      "--option",
      "fsync-store-paths",
      "true",
      "--option",
      "gc-reserved-space",
      "0",
      "--option",
      "accept-flake-config",
      "false" | args
    ]

    command =
      case options[:stdout_file] do
        nil ->
          case options[:stdin_file] do
            nil ->
              [
                System.find_executable("sh"),
                "-c",
                "ulimit -v 524288 || exit; exec \"$@\"",
                "work-store-nix" | command
              ]

            filename ->
              [
                System.find_executable("sh"),
                "-c",
                "ulimit -v 524288 || exit; input=\"$1\"; shift; exec \"$@\" < \"$input\"",
                "work-store-nix",
                filename | command
              ]
          end

        filename ->
          blocks = max(128, div(Keyword.fetch!(options, :stdout_limit) + 511, 512))

          [
            System.find_executable("sh"),
            "-c",
            "ulimit -f \"$1\" || exit; ulimit -v 524288 || exit; shift; output=\"$1\"; shift; exec \"$@\" > \"$output\"",
            "work-store-nar",
            Integer.to_string(blocks),
            filename | command
          ]
      end

    if cancelled?() do
      {:error, :cancelled}
    else
      cache =
        Keyword.get(
          options,
          :client_cache,
          Path.join(Keyword.fetch!(options, :root), "client-cache")
        )

      result =
        case Rexec.run_link(command,
               owner: self(),
               env: [{"NIX_REMOTE", ""}, {"NIX_CONFIG", ""}, {"XDG_CACHE_HOME", cache}]
             ) do
          {:ok, runner, os_pid} -> await(runner, os_pid, [], 0, nil)
          {:error, reason} -> {:error, {:cleanup_unconfirmed, {:nix_start, reason}}}
        end

      if not is_nil(options[:client_cache]) or match?({:error, {:cleanup_unconfirmed, _}}, result) do
        result
      else
        case File.rm_rf(cache) do
          {:ok, _} -> result
          {:error, reason, _} -> {:error, {:cleanup_unconfirmed, {:client_cache, reason}}}
        end
      end
    end
  end

  def cancelled? do
    receive do
      :cancel -> Process.put(:work_store_cancelled, true)
      {:DOWN, _, :process, _, _} -> Process.put(:work_store_cancelled, true)
      {:EXIT, _, _} -> Process.put(:work_store_cancelled, true)
    after
      0 -> :ok
    end

    Process.get(:work_store_cancelled, false)
  end

  defp await(runner, os_pid, output, size, failure) do
    receive do
      {:stdout, ^os_pid, bytes} ->
        if size + byte_size(bytes) <= 128 * 1024 * 1024 do
          await(runner, os_pid, [bytes | output], size + byte_size(bytes), failure)
        else
          Rexec.kill_tree(runner, :sigkill)
          await(runner, os_pid, output, size, :metadata_too_large)
        end

      {:stderr, ^os_pid, _bytes} ->
        await(runner, os_pid, output, size, failure)

      {:cleanup_error, ^os_pid, message} ->
        await(runner, os_pid, output, size, {:cleanup_unconfirmed, message})

      :cancel ->
        Process.put(:work_store_cancelled, true)
        Rexec.kill_tree(runner, :sigkill)
        await(runner, os_pid, output, size, failure || :cancelled)

      {:EXIT, ^runner, :normal} when failure == nil ->
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}

      {:EXIT, ^runner, {:shutdown, {:exit_status, 0}}} when failure == nil ->
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}

      {:EXIT, ^runner, {:shutdown, {:cleanup_failed, message}}} ->
        {:error, {:cleanup_unconfirmed, message}}

      {:EXIT, ^runner, reason} ->
        case CloudHypervisor.Cleanup.completion(reason) do
          {:ok, _} -> {:error, failure || {:nix_failed, reason}}
          {:error, message} -> {:error, {:cleanup_unconfirmed, message}}
        end

      {:DOWN, _, :process, _, _} ->
        Process.put(:work_store_cancelled, true)
        Rexec.kill_tree(runner, :sigkill)
        await(runner, os_pid, output, size, failure || :cancelled)

      {:EXIT, _parent, _reason} ->
        Process.put(:work_store_cancelled, true)
        Rexec.kill_tree(runner, :sigkill)
        await(runner, os_pid, output, size, failure || :cancelled)
    after
      60_000 ->
        Rexec.kill_tree(runner, :sigkill)
        await(runner, os_pid, output, size, failure || :nix_timeout)
    end
  end

  def info(options, store, paths, recursive \\ true) do
    args =
      ["path-info", "--store", store, "--json", "--json-format", "1"] ++
        if(recursive, do: ["--recursive"], else: []) ++ paths

    with {:ok, json} <- run(options, args),
         {:ok, value} <- Jason.decode(json),
         false <- Enum.any?(value, fn {_path, info} -> is_nil(info) end) do
      {:ok, Enum.map(value, fn {path, info} -> Map.put(info, "path", path) end)}
    else
      {:error, reason} -> {:error, reason}
      true -> {:error, :not_found}
    end
  end

  def catalog(options) do
    with {:ok, bytes} <- run(options, ["path-info", "--all", "--store", options[:root]]) do
      bytes
      |> String.split("\n", trim: true)
      |> Enum.chunk_every(128)
      |> Enum.reduce_while({:ok, []}, fn batch, {:ok, rows} ->
        case info(options, options[:root], batch, false) do
          {:ok, entries} ->
            compact =
              Enum.map(entries, fn entry ->
                %{"path" => :binary.copy(entry["path"]), "narSize" => entry["narSize"]}
              end)

            {:cont, {:ok, [compact | rows]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, rows |> Enum.reverse() |> List.flatten()}
        failure -> failure
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def referrers(options, path) do
    executable = Path.join(Path.dirname(Keyword.fetch!(options, :nix)), "nix-store")

    with {:ok, bytes} <-
           run(Keyword.put(options, :nix, executable), [
             "--query",
             "--referrers-closure",
             "--store",
             options[:root],
             path
           ]) do
      {:ok, String.split(bytes, "\n", trim: true)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(options, paths) do
    cache = Path.join(options[:root], "client-cache")
    filename = Path.join(cache, "delete.paths")
    executable = Path.join(Path.dirname(Keyword.fetch!(options, :nix)), "nix-store")

    with :ok <- File.mkdir_p(cache),
         :ok <- File.write(filename, Enum.intersperse(paths, "\n")),
         {:ok, output} <-
           run(options |> Keyword.put(:nix, executable) |> Keyword.put(:stdin_file, filename), [
             "--delete",
             "--stdin",
             "--store",
             options[:root]
           ]) do
      {:ok, output}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def copy(options, from, to, paths, extra \\ []) do
    run(options, ["copy", "--from", from, "--to", to] ++ extra ++ paths)
  end
end
