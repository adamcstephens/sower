defmodule Garden.WorkStore.Operations do
  @moduledoc false
  alias Garden.WorkStore.{Data, Run, Nix, Narinfo}

  def load(options) do
    root = Keyword.fetch!(options, :root)

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         false <- File.exists?(Path.join(root, "operation.pending")),
         :ok <- File.mkdir_p(Path.join(root, "runs")),
         :ok <- File.mkdir_p(Path.join(root, "cache")),
         :ok <- File.mkdir_p(Path.join(root, "staging")),
         :ok <- File.mkdir_p(Path.join(root, "closed")),
         {:ok, stale} <- File.ls(Path.join(root, "staging")),
         {:ok, closed_names} <- File.ls(Path.join(root, "closed")),
         {:ok, all} <- Nix.catalog(options),
         {:ok, names} <- File.ls(Path.join(root, "runs")) do
      retained =
        Enum.sum(
          Enum.map(stale, fn name ->
            max(options[:transfer_bytes], directory_bytes(Path.join([root, "staging", name])))
          end)
        )

      options = Keyword.put(options, :retained_staging_bytes, retained)

      Enum.each(closed_names, fn name ->
        File.rm_rf(Path.join([root, "nix/var/nix/gcroots/work-store", name]))
        File.rm_rf(Path.join([root, "runs", name]))
      end)

      names = Enum.reject(names, &(&1 in closed_names))

      closed =
        Enum.reduce(closed_names, MapSet.new(), fn name, closed ->
          MapSet.put(closed, File.read!(Path.join([root, "closed", name])))
        end)

      Enum.reduce_while(
        names,
        {:ok, remember(%Data{options: options, closed: closed}, all)},
        fn name, {:ok, data} ->
          with {:ok, bytes} <- File.read(Path.join([root, "runs", name, "run.json"])),
               {:ok, saved} <- Jason.decode(bytes),
               run <-
                 struct!(
                   Run,
                   Enum.map(saved, fn {key, value} -> {String.to_existing_atom(key), value} end)
                 ),
               true <- directory(data, run.sid) == Path.join([root, "runs", name]),
               {:ok, entries} <- infos(data, Enum.uniq(run.authorized ++ run.outputs)),
               :ok <- roots(data, run.sid, run.authorized, "inputs"),
               :ok <- roots(data, run.sid, run.outputs, "outputs") do
            data = %{data | runs: Map.put(data.runs, run.sid, run)} |> remember(entries)
            {:cont, {:ok, data}}
          else
            {:error, reason} -> {:halt, {:error, {:persistent_run, name, reason}}}
            _ -> {:halt, {:error, :invalid_persistent_run}}
          end
        end
      )
      |> check_reservations()
    else
      {:error, reason} -> {:error, reason}
      true -> {:error, :work_store_cleanup_unconfirmed}
    end
  end

  defp check_reservations({:ok, %Data{} = data}) do
    if Enum.sum(Enum.map(data.runs, fn {_, run} -> run.budget end)) <= data.options[:output_bytes] and
         input_bytes(data, [], []) <= data.options[:cache_bytes] and
         data.options[:retained_staging_bytes] <= data.options[:staging_bytes],
       do: {:ok, data},
       else: {:error, :persistent_reservations_exceed_capacity}
  end

  defp check_reservations(error), do: error

  def perform(%Data{} = data, {:open, sid, inputs, upstreams, budget}) do
    cond do
      not valid_context?(sid, inputs, upstreams, budget) ->
        {{:error, :invalid_run}, data}

      MapSet.member?(data.closed, sid) ->
        {{:error, :run_closed}, data}

      Map.has_key?(data.runs, sid) ->
        run = data.runs[sid]

        if {run.inputs, run.upstreams, run.budget} ==
             {Enum.sort(Enum.uniq(inputs)), upstreams, budget},
           do: {:ok, data},
           else: {{:error, :run_conflict}, data}

      budget > data.options[:output_bytes] ->
        {{:error, :output_budget_exceeds_capacity}, data}

      budget + Enum.sum(Enum.map(data.runs, fn {_, run} -> run.budget end)) >
          data.options[:output_bytes] ->
        {{:error, :output_capacity_exhausted}, data}

      true ->
        open(data, sid, Enum.sort(Enum.uniq(inputs)), upstreams, budget)
    end
  end

  def perform(%Data{} = data, {:close, sid}) do
    tombstone =
      Path.join([
        data.options[:root],
        "closed",
        Base.encode16(:crypto.hash(:sha256, sid), case: :lower)
      ])

    with :ok <- File.write(tombstone, sid, [:sync]),
         {:ok, _} <- File.rm_rf(root_directory(data, sid)),
         {:ok, _} <- File.rm_rf(directory(data, sid)) do
      data = %{data | runs: Map.delete(data.runs, sid), closed: MapSet.put(data.closed, sid)}

      case evict(data, 0) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {{:error, reason}, data}
      end
    else
      {:error, reason, _} -> {{:error, {:root_cleanup, reason}}, data}
      {:error, reason} -> {{:error, {:root_cleanup, reason}}, data}
    end
  end

  def perform(%Data{} = data, :refresh) do
    with {:ok, data} <- reconcile(data),
         {:ok, data} <- evict(data, 0) do
      {:ok, %{data | dirty: false}}
    else
      {:error, reason} -> {{:error, reason}, data}
    end
  end

  def perform(%Data{} = data, :gc) do
    # All live run roots are persistent; collection cannot touch them.
    with {:ok, data} <- evict(data, 0, true),
         {:ok, _} <- Nix.run(data.options, ["store", "gc", "--store", data.options[:root]]),
         {:ok, data} <- reconcile(data) do
      {:ok, data}
    else
      {:error, reason} -> {{:error, reason}, data}
    end
  end

  def perform(%Data{} = data, {:read, sid, key}) do
    path = authorized_path(data, sid, key)

    if path do
      with {:ok, updated} <- cache(data, path),
           {:ok, bytes} <- File.read(Path.join(cache_directory(data), key)),
           {:ok, info} <- Narinfo.parse(bytes, key) do
        {{:ok, bytes, info.url, Path.join(cache_directory(data), info.url)}, updated}
      else
        {:error, reason} -> {{:error, reason}, data}
      end
    else
      {{:error, :not_found}, data}
    end
  end

  def perform(%Data{} = data, {:export, sid, key}) do
    path = authorized_path(data, sid, key)

    if path do
      with {:ok, entries} <- infos(data, [path]),
           {:ok, updated, paths, new_paths} <- prepare_export(data.runs[sid], entries),
           {{:ok, bytes, url, filename}, data} <- perform(data, {:read, sid, key}),
           :ok <- cancelled(),
           :ok <- publish(data, updated, paths, new_paths) do
        {{:ok, bytes, url, filename, paths}, %{data | runs: Map.put(data.runs, sid, updated)}}
      else
        {{:error, reason}, changed} -> {{:error, reason}, changed}
        {:error, reason} -> {{:error, reason}, data}
      end
    else
      {{:error, :not_found}, data}
    end
  end

  def perform(%Data{} = data, {:commit, sid, stage, key, _token}) do
    with %Run{} = run <- data.runs[sid],
         {:ok, bytes} <- File.read(Path.join(stage, key)),
         {:ok, info} <- Narinfo.parse(bytes, key),
         true <-
           Enum.all?(
             info.references,
             &(&1 == info.path or &1 in run.authorized or &1 in run.outputs)
           ),
         {:ok, stat} <- File.stat(Path.join(stage, info.url)),
         true <- stat.size == info.file_size,
         {:ok, file_hash} <-
           Nix.run(data.options, [
             "hash",
             "file",
             "--store",
             data.options[:root],
             "--type",
             "sha256",
             "--base32",
             Path.join(stage, info.url)
           ]),
         true <- "sha256:" <> String.trim(file_hash) == info.fields["FileHash"],
         {:ok, data, committed} <- commit(data, run, info, stage) do
      {{:ok, committed}, data}
    else
      nil -> {{:error, :run_closed}, data}
      false -> {{:error, :invalid_closure}, data}
      {:error, reason} -> {{:error, reason}, data}
    end
  end

  defp open(data, sid, inputs, upstreams, budget) do
    with {:ok, entries} <- resolve_inputs(data, inputs, upstreams),
         paths <- Enum.map(entries, & &1["path"]),
         true <- input_bytes(data, paths, entries) <= data.options[:cache_bytes],
         missing <- Enum.reject(entries, &Map.has_key?(data.objects, &1["path"])),
         admitting <- %{
           data
           | runs:
               Map.put(data.runs, sid, %Run{
                 sid: sid,
                 inputs: inputs,
                 upstreams: upstreams,
                 budget: budget,
                 authorized: paths
               })
         },
         {:ok, data} <- evict(admitting, Enum.sum(Enum.map(missing, &charge(&1["narSize"])))),
         :ok <- import_inputs(data, inputs, upstreams),
         {:ok, entries} <- infos(data, inputs),
         paths <- Enum.map(entries, & &1["path"]),
         true <- input_bytes(data, paths, entries) <= data.options[:cache_bytes],
         :ok <- roots(data, sid, paths, "inputs"),
         run <- %Run{
           sid: sid,
           inputs: inputs,
           upstreams: upstreams,
           budget: budget,
           authorized: Enum.sort(paths)
         },
         :ok <- save(data, run) do
      {:ok, %{data | runs: Map.put(data.runs, sid, run)} |> remember(entries)}
    else
      false -> failed_open(data, sid, :input_cache_capacity_exhausted)
      {:error, reason} -> failed_open(data, sid, reason)
    end
  end

  defp failed_open(data, sid, reason) do
    with {:ok, _} <- File.rm_rf(root_directory(data, sid)),
         {:ok, _} <- File.rm_rf(directory(data, sid)) do
      {{:error, reason}, data}
    else
      {:error, failure, _} -> {{:error, {:cleanup_unconfirmed, failure}}, data}
    end
  end

  defp import_inputs(data, inputs, upstreams) do
    Enum.reduce_while(inputs, :ok, fn path, :ok ->
      case Nix.info(data.options, data.options[:root], [path]) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, _} ->
          result =
            Enum.reduce_while(upstreams, {:error, :input_unavailable}, fn upstream, _ ->
              case Nix.copy(data.options, upstream, data.options[:root], [path]) do
                {:ok, _} -> {:halt, :ok}
                {:error, reason} -> {:cont, {:error, reason}}
              end
            end)

          case result do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp infos(_data, []), do: {:ok, []}
  defp infos(data, paths), do: Nix.info(data.options, data.options[:root], paths)

  defp input_bytes(data, paths, entries) do
    live = Enum.flat_map(data.runs, fn {_, run} -> run.authorized end) |> Enum.uniq()
    bytes = Map.new(entries, &{&1["path"], &1["narSize"]})

    Enum.uniq(live ++ paths)
    |> Enum.reduce(0, fn path, total ->
      total + charge(bytes[path] || get_in(data.objects, [path, :size]) || 0)
    end)
  end

  defp charge(nar_size), do: 2 * nar_size + 65_536

  defp resolve_inputs(data, inputs, upstreams) do
    Enum.reduce_while(inputs, {:ok, []}, fn path, {:ok, entries} ->
      stores = [data.options[:root] | upstreams]

      result =
        Enum.reduce_while(stores, {:error, :input_unavailable}, fn store, _ ->
          case Nix.info(data.options, store, [path]) do
            {:ok, found} -> {:halt, {:ok, found}}
            {:error, reason} -> {:cont, {:error, reason}}
          end
        end)

      case result do
        {:ok, found} -> {:cont, {:ok, Enum.uniq_by(entries ++ found, & &1["path"])}}
        error -> {:halt, error}
      end
    end)
  end

  defp commit(data, run, info, stage) do
    new? = info.path not in run.outputs

    if new? and run.used + charge(info.nar_size) > run.budget do
      {:error, :output_budget_exceeded}
    else
      validation = Path.join(stage, "validation")
      refs = Enum.reject(info.references, &(&1 == info.path))

      with {:ok, ref_entries} <- infos(data, refs),
           {:ok, updated, paths, new_paths} <-
             prepare_export(run, [
               %{"path" => info.path, "narSize" => info.nar_size} | ref_entries
             ]),
           true <-
             directory_bytes(stage) + info.nar_size + max(2 * info.nar_size + 1024, 128 * 1024) +
               512 * 1024 + Enum.sum(Enum.map(ref_entries, &(2 * (&1["narSize"] + 65_536)))) <=
               data.options[:transfer_bytes],
           {:ok, validated_cache} <- bounded_nar(data, info, stage),
           :ok <- copy_refs(data, "file://" <> validated_cache <> "?compression=none", refs),
           :ok <- File.mkdir_p(validation),
           :ok <- copy_refs(data, validation, refs),
           {:ok, _} <-
             Nix.copy(
               data.options,
               "file://" <> validated_cache <> "?trusted=true",
               validation,
               [info.path],
               ["--no-check-sigs"]
             ),
           {:ok, [entry]} <- Nix.info(data.options, validation, [info.path], false),
           true <-
             entry["narSize"] == info.nar_size and
               Enum.sort(entry["references"]) == Enum.sort(info.references),
           :ok <- existing_matches(data, entry),
           :ok <- cancelled(),
           {:ok, _} <-
             Nix.copy(data.options, validation, data.options[:root], [info.path], [
               "--no-check-sigs"
             ]),
           :ok <- publish(data, updated, paths, new_paths) do
        # A retained validation directory is still charged to this execution;
        # detach may certify it only after removal succeeds.
        Nix.remove_tree(validation)
        Nix.remove_tree(validated_cache)

        {:ok, %{data | runs: Map.put(data.runs, run.sid, updated)} |> remember([entry]), paths}
      else
        false -> {:error, :invalid_closure}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_closure}
      end
    end
  end

  defp bounded_nar(data, info, stage) do
    directory = Path.join(stage, "validated-cache")
    filename = Path.join([directory, "nar", "validated.nar"])

    options =
      data.options
      |> Keyword.put(:stdout_file, filename)
      |> Keyword.put(:stdout_limit, info.nar_size)
      |> Keyword.put(:client_cache, Path.join(directory, "client-cache"))

    with :ok <- File.mkdir_p(Path.dirname(filename)),
         {:ok, _} <-
           Nix.run(options, [
             "store",
             "dump-path",
             "--store",
             "file://" <> stage <> "?trusted=true",
             info.path
           ]),
         {:ok, stat} <- File.stat(filename),
         true <- stat.size == info.nar_size,
         {:ok, hash} <-
           Nix.run(data.options, [
             "hash",
             "file",
             "--store",
             data.options[:root],
             "--type",
             "sha256",
             "--base32",
             filename
           ]),
         true <- "sha256:" <> String.trim(hash) == info.fields["NarHash"],
         fields <-
           info.fields
           |> Map.put("URL", "nar/validated.nar")
           |> Map.put("Compression", "none")
           |> Map.put("FileHash", info.fields["NarHash"])
           |> Map.put("FileSize", Integer.to_string(info.nar_size)),
         bytes <- Enum.map_join(fields, "", fn {key, value} -> key <> ": " <> value <> "\n" end),
         :ok <- File.write(Path.join(directory, Narinfo.key(info.path)), bytes),
         :ok <- File.write(Path.join(directory, "nix-cache-info"), "StoreDir: /nix/store\n") do
      {:ok, directory}
    else
      false -> {:error, :invalid_nar}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_export(%Run{} = run, entries) do
    entries = Enum.uniq_by(entries, & &1["path"])
    paths = Enum.map(entries, & &1["path"])
    added = Enum.reject(entries, &(&1["path"] in run.outputs))
    used = run.used + Enum.sum(Enum.map(added, &charge(&1["narSize"])))

    if used <= run.budget do
      updated = %{run | outputs: Enum.sort(Enum.uniq(paths ++ run.outputs)), used: used}
      {:ok, updated, paths, Enum.map(added, & &1["path"])}
    else
      {:error, :output_budget_exceeded}
    end
  end

  defp publish(data, %Run{} = run, paths, new_paths) do
    with :ok <- roots(data, run.sid, paths, "outputs"),
         :ok <- save(data, run) do
      :ok
    else
      {:error, reason} ->
        cleanup =
          Enum.reduce_while(new_paths, :ok, fn path, :ok ->
            root = Path.join([root_directory(data, run.sid), "outputs", Narinfo.key(path)])

            case File.rm(root) do
              :ok -> {:cont, :ok}
              {:error, :enoent} -> {:cont, :ok}
              {:error, failure} -> {:halt, {:error, {:cleanup_unconfirmed, failure}}}
            end
          end)

        if cleanup == :ok, do: {:error, reason}, else: cleanup
    end
  end

  defp authorized_path(%Data{} = data, sid, key) do
    case data.runs[sid] do
      nil -> nil
      %Run{} = run -> Enum.find(run.authorized ++ run.outputs, &(Narinfo.key(&1) == key))
    end
  end

  defp copy_refs(_data, _validation, []), do: :ok

  defp copy_refs(data, validation, refs) do
    case Nix.copy(data.options, data.options[:root], validation, refs, ["--no-check-sigs"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp existing_matches(data, entry) do
    case Nix.info(data.options, data.options[:root], [entry["path"]], false) do
      {:ok, [existing]} ->
        if Enum.all?(["narHash", "narSize", "references"], &(existing[&1] == entry[&1])),
          do: :ok,
          else: {:error, :conflicting_path}

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancelled do
    if Nix.cancelled?(), do: {:error, :cancelled}, else: :ok
  end

  defp cache(data, path) do
    key = Path.join(cache_directory(data), Narinfo.key(path))

    if File.regular?(key) do
      {:ok, touch(data, path)}
    else
      with {:ok, data} <- evict(data, 0),
           {:ok, _} <-
             Nix.copy(
               data.options,
               data.options[:root],
               "file://" <> cache_directory(data) <> "?compression=none",
               [path]
             ) do
        {:ok, touch(data, path)}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp evict(data, requested, all \\ false) do
    pinned =
      Enum.flat_map(data.runs, fn {_, run} -> run.authorized ++ run.outputs end) |> MapSet.new()

    unpinned =
      data.objects
      |> Enum.reject(fn {path, _} -> MapSet.member?(pinned, path) end)
      |> Enum.sort_by(fn {_, object} -> object.touched end)

    Enum.reduce_while(unpinned, {:ok, data}, fn {path, _object}, {:ok, data} ->
      cond do
        not Map.has_key?(data.objects, path) ->
          {:cont, {:ok, data}}

        not all and cache_usage(data) + requested <= data.options[:cache_bytes] ->
          {:halt, {:ok, data}}

        true ->
          with {:ok, group} <- Nix.referrers(data.options, path),
               true <- Enum.all?(group, &(not MapSet.member?(pinned, &1))),
               {:ok, _} <- Nix.delete(data.options, group),
               :ok <- remove_cached_group(data, group) do
            {:cont, {:ok, %{data | objects: Map.drop(data.objects, group)}}}
          else
            false ->
              {:cont, {:ok, data}}

            {:error, {:cleanup_unconfirmed, _}} = failure ->
              {:halt, failure}

            {:error, :cancelled} = failure ->
              {:halt, failure}

            {:error, _} ->
              case reconcile(data) do
                {:ok, data} -> {:cont, {:ok, data}}
                failure -> {:halt, failure}
              end
          end
      end
    end)
    |> case do
      {:ok, data} ->
        if all or cache_usage(data) + requested <= data.options[:cache_bytes],
          do: {:ok, data},
          else: {:error, :cache_capacity_exhausted}

      error ->
        error
    end
  end

  defp reconcile(data) do
    with {:ok, entries} <- Nix.catalog(data.options) do
      valid = MapSet.new(entries, & &1["path"])
      removed = Enum.reject(Map.keys(data.objects), &MapSet.member?(valid, &1))

      with :ok <- remove_cached_group(data, removed) do
        retained = Map.filter(data.objects, fn {path, _} -> MapSet.member?(valid, path) end)
        {:ok, remember(%{data | objects: retained}, entries)}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp cache_usage(data) do
    output = Enum.flat_map(data.runs, fn {_, run} -> run.outputs end) |> MapSet.new()

    accounted =
      Enum.reduce(data.objects, 0, fn {path, object}, total ->
        total + if(MapSet.member?(output, path), do: 0, else: charge(object.size))
      end)

    representation_allowance =
      Enum.reduce(data.objects, 0, fn {_, object}, total -> total + object.size + 65_536 end)

    accounted + max(0, directory_bytes(cache_directory(data)) - representation_allowance)
  end

  defp directory_bytes(path) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.reduce(names, 0, fn name, total ->
          child = Path.join(path, name)

          case File.lstat(child) do
            {:ok, %{type: :regular, size: size}} -> total + size
            {:ok, %{type: :directory}} -> total + directory_bytes(child)
            _ -> total
          end
        end)

      _ ->
        0
    end
  end

  defp remove_cached_group(data, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case remove_cached(data, path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:cleanup_unconfirmed, {:cache, reason}}}}
      end
    end)
  end

  defp remove_cached(data, path) do
    filename = Path.join(cache_directory(data), Narinfo.key(path))

    with {:ok, bytes} <- File.read(filename),
         {:ok, info} <- Narinfo.parse(bytes, Narinfo.key(path)),
         :ok <- remove_file(filename),
         {:ok, names} <- File.ls(cache_directory(data)) do
      shared =
        Enum.any?(names, fn key ->
          if Narinfo.info?(key) do
            with {:ok, bytes} <- File.read(Path.join(cache_directory(data), key)),
                 {:ok, other} <- Narinfo.parse(bytes, key) do
              other.url == info.url
            else
              _ -> false
            end
          else
            false
          end
        end)

      if shared, do: :ok, else: remove_file(Path.join(cache_directory(data), info.url))
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remember(data, entries) do
    objects =
      Enum.reduce(entries, data.objects, fn entry, objects ->
        touched =
          case File.stat(Path.join(cache_directory(data), Narinfo.key(entry["path"])),
                 time: :posix
               ) do
            {:ok, stat} -> stat.mtime * 1000
            _ -> System.system_time(:millisecond)
          end

        old = Map.get(objects, entry["path"])

        Map.put(objects, entry["path"], %{
          size: entry["narSize"],
          touched: if(old, do: old.touched, else: touched)
        })
      end)

    %{data | objects: objects}
  end

  defp touch(data, path) do
    File.touch(Path.join(cache_directory(data), Narinfo.key(path)))
    put_in(data.objects[path].touched, System.system_time(:millisecond))
  end

  defp directory(data, sid),
    do:
      Path.join([
        data.options[:root],
        "runs",
        Base.encode16(:crypto.hash(:sha256, sid), case: :lower)
      ])

  defp cache_directory(data), do: Path.join(data.options[:root], "cache")

  defp root_directory(data, sid),
    do:
      Path.join([
        data.options[:root],
        "nix/var/nix/gcroots/work-store",
        Base.encode16(:crypto.hash(:sha256, sid), case: :lower)
      ])

  defp roots(data, sid, paths, kind) do
    directory = Path.join(root_directory(data, sid), kind)

    with {:ok, _} <- infos(data, paths),
         :ok <- File.mkdir_p(directory) do
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        destination = Path.join(directory, Narinfo.key(path))

        case File.read_link(destination) do
          {:ok, ^path} ->
            {:cont, :ok}

          {:error, :enoent} ->
            case File.ln_s(path, destination) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          _ ->
            {:halt, {:error, :conflicting_gcroot}}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp save(data, run) do
    directory = directory(data, run.sid)

    with :ok <- File.mkdir_p(directory),
         :ok <-
           File.write(Path.join(directory, "run.json.new"), Jason.encode!(Map.from_struct(run)), [
             :sync
           ]),
         :ok <-
           File.rename(Path.join(directory, "run.json.new"), Path.join(directory, "run.json")) do
      :ok
    else
      {:error, reason} -> {:error, {:persistent_manifest, reason}}
    end
  end

  defp valid_context?(sid, inputs, upstreams, budget) do
    is_binary(sid) and byte_size(sid) in 1..256 and is_list(inputs) and
      Enum.all?(inputs, &Narinfo.path?/1) and is_list(upstreams) and
      Enum.all?(upstreams, fn url ->
        is_binary(url) and URI.parse(url).scheme in ["https", "http", "file"]
      end) and is_integer(budget) and budget > 0
  end
end
