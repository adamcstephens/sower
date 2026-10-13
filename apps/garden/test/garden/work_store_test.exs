defmodule Garden.WorkStoreTest do
  use ExUnit.Case, async: false
  alias Garden.WorkStore
  alias Garden.WorkStore.Narinfo

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ws-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    {:ok, _} = Application.ensure_all_started(:bandit)

    options = [
      root: Path.join(directory, "work"),
      output_bytes: 1024 * 1024,
      cache_bytes: 1024 * 1024,
      staging_bytes: 4 * 1024 * 1024,
      transfer_bytes: 1024 * 1024
    ]

    {:ok, store} = WorkStore.start_link(options)
    Process.unlink(store)

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      File.rm_rf!(directory)
    end)

    {:ok, store: store, options: options, directory: directory}
  end

  test "abandoning a partial upload releases an already queued commit lock", context do
    alias Garden.WorkStore.Service
    :ok = WorkStore.open_run(context.store, "abandoned", [], [], 128 * 1024)
    transfer = attach(context, "abandoned", "abandoned")
    key = "nar/" <> String.duplicate("0", 52) <> ".nar"
    {:ok, upload, _filename} = Service.begin_upload(transfer.service, key, 128)
    request = :gen_server.send_request(transfer.service, :lock)
    assert :ok = Service.abandon(transfer.service, upload)
    assert {:reply, {:ok, lock}} = :gen_server.wait_response(request, 1000)
    Service.unlock(transfer.service, lock)
    assert :ok = WorkStore.detach(transfer)
    refute_receive {:work_store_paths, "abandoned", _}
  end

  test "write-side deduplication roots and reports an authorized existing closure", context do
    {path, cache} = exported(context.directory, "dedup-input", "already imported")
    :ok = WorkStore.open_run(context.store, "dedup", [path], ["file://" <> cache], 128 * 1024)
    transfer = attach(context, "dedup", "dedup")
    assert {200, ""} = request(transfer, :write, "HEAD", Narinfo.key(path))
    assert {:ok, [^path]} = WorkStore.paths(context.store, "dedup")
    assert_receive {:work_store_paths, "dedup", [^path]}
    :ok = WorkStore.open_run(context.store, "unrelated", [], [], 128 * 1024)
    other = attach(context, "unrelated", "unrelated")
    assert {404, _} = request(other, :write, "HEAD", Narinfo.key(path))
    assert {:ok, []} = WorkStore.paths(context.store, "unrelated")
    assert :ok = WorkStore.detach(transfer)
    assert :ok = WorkStore.detach(other)
  end

  test "an exported output associates its already cached reference closure with the run",
       context do
    {input, input_cache} = exported(context.directory, "reference-input", "declared input")
    source = Path.join(context.directory, "reference-input-source")

    expression =
      "builtins.toFile \"referencing-output\" (builtins.storePath #{Jason.encode!(input)})"

    output =
      nix!(["eval", "--impure", "--raw", "--store", source, "--expr", expression])
      |> String.trim()

    cache = Path.join(context.directory, "reference-output-cache")
    nix!(["copy", "--from", source, "--to", "file://" <> cache <> "?compression=xz", output])

    :ok =
      WorkStore.open_run(
        context.store,
        "references",
        [input],
        ["file://" <> input_cache],
        256 * 1024
      )

    transfer = attach(context, "references", "references")
    assert upload(transfer, output, cache) == 200
    paths = Enum.sort([input, output])
    assert {:ok, ^paths} = WorkStore.paths(context.store, "references")
    assert_receive {:work_store_paths, "references", ^paths}
    assert File.read!(context.options[:root] <> output) == input
    assert :ok = WorkStore.detach(transfer)
    assert :ok = WorkStore.gc(context.store)
    assert File.exists?(context.options[:root] <> input)
  end

  test "unsigned input-addressed uploads are isolated, durable and independently rooted",
       context do
    source = Path.join(context.directory, "directory-source")
    directory = Path.join(context.directory, "directory-output")
    File.mkdir!(directory)
    File.write!(Path.join(directory, "value"), "guest-produced bytes")
    File.ln_s!("/outside-validation-store", Path.join(directory, "outside"))
    path = nix!(["store", "add-path", "--store", source, directory]) |> String.trim()
    cache = Path.join(context.directory, "directory-cache")
    nix!(["copy", "--from", source, "--to", "file://" <> cache <> "?compression=xz", path])
    nix!(["store", "gc", "--store", source])
    filename = Path.join(cache, Narinfo.key(path))
    File.write!(filename, Regex.replace(~r/^CA:.*\n/m, File.read!(filename), ""))
    :ok = WorkStore.open_run(context.store, "run", [], [], 256 * 1024)
    transfer = attach(context, "run", "first")
    assert upload(transfer, path, cache) == 200
    assert_receive {:work_store_paths, "first", [^path]}
    assert {:ok, [^path]} = WorkStore.paths(context.store, "run")
    assert File.read!(context.options[:root] <> path <> "/value") == "guest-produced bytes"

    assert File.read_link!(context.options[:root] <> path <> "/outside") ==
             "/outside-validation-store"

    refute File.exists?(path)
    assert :ok = WorkStore.detach(transfer)
    assert :ok = WorkStore.gc(context.store)
    assert File.exists?(context.options[:root] <> path)

    GenServer.stop(context.store)
    {:ok, restarted} = WorkStore.start_link(context.options)
    Process.unlink(restarted)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    assert {:ok, [^path]} = WorkStore.paths(restarted, "run")
    assert :ok = WorkStore.open_run(restarted, "independent", [path], [], 256 * 1024)
    assert :ok = WorkStore.close_run(restarted, "run")
    assert :ok = WorkStore.close_run(restarted, "run")
    assert {:error, :run_closed} = WorkStore.open_run(restarted, "run", [], [], 256 * 1024)
    assert :ok = WorkStore.gc(restarted)
    assert File.exists?(context.options[:root] <> path)
    assert :ok = WorkStore.close_run(restarted, "independent")
    assert :ok = WorkStore.gc(restarted)
    refute File.exists?(context.options[:root] <> path)
  end

  test "authorized upstream closure stays warm without granting another run its NAR", context do
    {path, cache} = exported(context.directory, "input", "authorized upstream")

    :ok =
      WorkStore.open_run(
        context.store,
        "authorized",
        [path],
        ["file://" <> cache <> "?trusted=true"],
        128 * 1024
      )

    :ok = WorkStore.open_run(context.store, "other", [], [], 128 * 1024)
    first = attach(context, "authorized", "reader")
    other = attach(context, "other", "other-reader")
    assert {200, body} = request(first, :read, "GET", Narinfo.key(path))
    {:ok, info} = Narinfo.parse(body, Narinfo.key(path))
    assert {404, _} = request(other, :read, "GET", Narinfo.key(path))
    assert {404, _} = request(other, :read, "GET", info.url)
    assert {404, _} = request(first, :read, "GET", "../../etc/passwd")
    assert :ok = WorkStore.detach(first)
    File.rm_rf!(cache)

    assert :ok =
             WorkStore.open_run(
               context.store,
               "authorized",
               [path],
               ["file://" <> cache <> "?trusted=true"],
               128 * 1024
             )

    second = attach(context, "authorized", "warm-reader")
    assert {200, _} = request(second, :read, "GET", Narinfo.key(path))
    assert {200, nar} = request(second, :read, "GET", info.url)
    assert byte_size(nar) == info.file_size
    assert :ok = WorkStore.detach(second)
    assert :ok = WorkStore.detach(other)
  end

  test "corruption, output pressure and conflicting NAR uploads never publish", context do
    {path, cache} = exported(context.directory, "corrupt", "correct payload")
    info_bytes = File.read!(Path.join(cache, Narinfo.key(path)))
    {:ok, info} = Narinfo.parse(info_bytes, Narinfo.key(path))
    nar = File.read!(Path.join(cache, info.url))
    :ok = WorkStore.open_run(context.store, "corrupt", [], [], 128 * 1024)
    bad = attach(context, "corrupt", "bad")
    corrupt = :binary.copy("x", byte_size(nar))
    assert {200, _} = request(bad, :write, "PUT", info.url, corrupt)
    assert {409, _} = request(bad, :write, "PUT", info.url, nar)
    assert {409, _} = request(bad, :write, "PUT", Narinfo.key(path), info_bytes)
    assert {:ok, []} = WorkStore.paths(context.store, "corrupt")
    refute File.exists?(context.options[:root] <> path)
    assert :ok = WorkStore.detach(bad)
    refute_receive {:work_store_paths, "bad", _}

    :ok = WorkStore.open_run(context.store, "tiny", [], [], 1)
    tiny = attach(context, "tiny", "tiny")
    assert {200, _} = request(tiny, :write, "PUT", info.url, nar)
    assert {413, _} = request(tiny, :write, "PUT", Narinfo.key(path), info_bytes)
    assert {:ok, []} = WorkStore.paths(context.store, "tiny")
    assert :ok = WorkStore.detach(tiny)
    refute_receive {:work_store_paths, "tiny", _}
  end

  test "other-run references are rejected even when already in the work store", context do
    {path, cache} = exported(context.directory, "secret", "other-run reference")

    :ok =
      WorkStore.open_run(
        context.store,
        "secret",
        [path],
        ["file://" <> cache <> "?trusted=true"],
        128 * 1024
      )

    {output, output_cache} = exported(context.directory, "unrelated", "not a closure")
    info_bytes = File.read!(Path.join(output_cache, Narinfo.key(output)))
    {:ok, info} = Narinfo.parse(info_bytes, Narinfo.key(output))
    forged = String.replace(info_bytes, "References: \n", "References: #{Path.basename(path)}\n")
    :ok = WorkStore.open_run(context.store, "attacker", [], [], 128 * 1024)
    transfer = attach(context, "attacker", "attacker")

    assert {200, _} =
             request(
               transfer,
               :write,
               "PUT",
               info.url,
               File.read!(Path.join(output_cache, info.url))
             )

    assert {409, _} = request(transfer, :write, "PUT", Narinfo.key(output), forged)
    assert {:ok, []} = WorkStore.paths(context.store, "attacker")
    assert :ok = WorkStore.detach(transfer)
  end

  test "run-close revokes uploads and frees only certified staging reservations", context do
    :ok = WorkStore.open_run(context.store, "closing", [], [], 128 * 1024)
    transfer = attach(context, "closing", "closing")
    assert :ok = WorkStore.close_run(context.store, "closing")
    assert :ok = WorkStore.detach(transfer)
    Enum.each(transfer.sockets, &refute(File.exists?(&1)))

    assert {:error, :run_closed} =
             WorkStore.attach(context.store, "closing", "late", context.directory, self(), 1000)

    assert :ok = WorkStore.open_run(context.store, "full", [], [], 1024 * 1024)

    assert {:error, :output_capacity_exhausted} =
             WorkStore.open_run(context.store, "over", [], [], 1)
  end

  test "unknown owned-socket replacement is retained and cleanup cannot be certified", context do
    :ok = WorkStore.open_run(context.store, "unknown", [], [], 128 * 1024)
    transfer = attach(context, "unknown", "unknown")
    socket = hd(transfer.sockets)
    File.rm!(socket)
    File.write!(socket, "unknown file")
    assert {:error, :unexpected_socket_file} = WorkStore.detach(transfer)
    assert File.read!(socket) == "unknown file"
    File.rm!(socket)
    assert :ok = WorkStore.detach(transfer)
  end

  test "forged tiny NarSize cannot inflate staging before Nix validates", context do
    {path, cache} = exported(context.directory, "bomb", :binary.copy("a", 2 * 1024 * 1024))
    info_bytes = File.read!(Path.join(cache, Narinfo.key(path)))
    {:ok, info} = Narinfo.parse(info_bytes, Narinfo.key(path))
    forged = String.replace(info_bytes, "NarSize: #{info.nar_size}\n", "NarSize: 1\n")
    :ok = WorkStore.open_run(context.store, "bomb", [], [], 128 * 1024)
    transfer = attach(context, "bomb", "bomb")

    assert {200, _} =
             request(transfer, :write, "PUT", info.url, File.read!(Path.join(cache, info.url)))

    assert {409, _} = request(transfer, :write, "PUT", Narinfo.key(path), forged)
    assert {:ok, []} = WorkStore.paths(context.store, "bomb")
    {:ok, _, _, stage, _} = Garden.WorkStore.Service.context(transfer.service)

    case File.stat(Path.join(stage, "validated-cache/nar/validated.nar")) do
      {:ok, stat} -> assert stat.size <= 128 * 1024
      {:error, :enoent} -> :ok
    end

    refute File.exists?(context.options[:root] <> path)
    assert :ok = WorkStore.detach(transfer)
  end

  test "declared derivation roots are protected without evaluating a host build", context do
    source = Path.join(context.directory, "derivation-source")
    sentinel = Path.join(context.directory, "host-builder-ran")

    expression =
      "(builtins.derivation { name = \"host-never-build\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" #{Jason.encode!("touch " <> sentinel <> "; exit 1")} ]; }).drvPath"

    path =
      nix!(["eval", "--impure", "--raw", "--store", source, "--expr", expression])
      |> String.trim()

    cache = Path.join(context.directory, "derivation-cache")
    nix!(["copy", "--from", source, "--to", "file://" <> cache, path])

    assert :ok =
             WorkStore.open_run(
               context.store,
               "derivation",
               [path],
               ["file://" <> cache <> "?trusted=true"],
               128 * 1024
             )

    assert :ok = WorkStore.gc(context.store)
    assert File.exists?(context.options[:root] <> path)
    refute File.exists?(sentinel)
  end

  test "parallel repeated real exports preserve run ownership and teardown ordering", context do
    {path, cache} = exported(context.directory, "parallel", "one immutable output")
    :ok = WorkStore.open_run(context.store, "parallel", [], [], 128 * 1024)
    first = attach(context, "parallel", "parallel-first")
    second = attach(context, "parallel", "parallel-second")

    tasks =
      Enum.map([first, second], fn transfer ->
        Task.async(fn -> upload(transfer, path, cache) end)
      end)

    assert Enum.map(tasks, &Task.await(&1, 30_000)) == [200, 200]
    assert {:ok, [^path]} = WorkStore.paths(context.store, "parallel")
    assert :ok = WorkStore.detach(first)
    assert_receive {:work_store_paths, "parallel-first", [^path]}
    assert :ok = WorkStore.detach(second)
    assert_receive {:work_store_paths, "parallel-second", [^path]}
    assert :ok = WorkStore.gc(context.store)
    assert File.exists?(context.options[:root] <> path)
  end

  test "admission caller death reaps a real stalled Nix upstream and leaves cancellation responsive",
       context do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    upstream =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 10_000)
        send(parent, :upstream_stalled)
        result = :gen_tcp.recv(socket, 0, 10_000)
        send(parent, {:upstream_connection, result})
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(upstream, :kill)
    end)

    path = "/nix/store/00000000000000000000000000000000-stalled"

    admission =
      spawn(fn ->
        WorkStore.open_run(
          context.store,
          "stalled",
          [path],
          ["http://127.0.0.1:#{port}"],
          128 * 1024
        )
      end)

    assert_receive :upstream_stalled, 10_000
    Process.exit(admission, :kill)
    assert_receive {:upstream_connection, {:error, :closed}}, 10_000
    collection = Task.async(fn -> WorkStore.gc(context.store) end)
    assert Task.await(collection, 10_000) == :ok
    assert {:error, :run_closed} = WorkStore.paths(context.store, "stalled")
    assert :ok = WorkStore.open_run(context.store, "after-cancel", [], [], 128 * 1024)
  end

  test "closing an output-heavy run enforces the unpinned cache budget", context do
    options =
      Keyword.merge(context.options,
        root: Path.join(context.directory, "limited-work"),
        cache_bytes: 65_536
      )

    {:ok, store} = WorkStore.start_link(options)
    Process.unlink(store)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    {path, cache} = exported(context.directory, "cache-pressure", :binary.copy("p", 8192))
    :ok = WorkStore.open_run(store, "pressure", [], [], 128 * 1024)
    transfer = attach(%{context | store: store}, "pressure", "pressure")
    assert upload(transfer, path, cache) == 200
    assert :ok = WorkStore.detach(transfer)
    assert :ok = WorkStore.gc(store)
    assert File.exists?(options[:root] <> path)
    assert :ok = WorkStore.close_run(store, "pressure")
    refute File.exists?(options[:root] <> path)
    assert {:error, :run_closed} = WorkStore.paths(store, "pressure")
  end

  test "a killed store cannot release root custody while native work is still active", context do
    Process.flag(:trap_exit, true)
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    upstream =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 10_000)
        send(parent, :native_work_stalled)
        send(parent, {:native_work_connection, :gen_tcp.recv(socket, 0, 10_000)})
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(upstream, :kill)
    end)

    spawn(fn ->
      WorkStore.open_run(
        context.store,
        "killed-owner",
        ["/nix/store/00000000000000000000000000000000-stalled"],
        ["http://127.0.0.1:#{port}"],
        128 * 1024
      )
    end)

    assert_receive :native_work_stalled, 10_000
    {worker, _, _, _, _} = :sys.get_state(context.store).busy
    worker_monitor = Process.monitor(worker)
    true = :erlang.suspend_process(worker)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    store_monitor = Process.monitor(context.store)
    Process.exit(context.store, :kill)
    assert_receive {:DOWN, ^store_monitor, :process, _, :killed}
    assert {:error, :work_store_already_owned} = WorkStore.start_link(context.options)
    true = :erlang.resume_process(worker)
    assert_receive {:native_work_connection, {:error, :closed}}, 10_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 10_000
    {:ok, restarted} = WorkStore.start_link(context.options)
    Process.unlink(restarted)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    assert {:error, :run_closed} = WorkStore.paths(restarted, "killed-owner")
    assert :ok = WorkStore.open_run(restarted, "after-native-cleanup", [], [], 128 * 1024)
  end

  test "ordinary gzip NARs with a gzip URL validate and import", context do
    {path, _} = exported(context.directory, "gzip", "gzip payload")
    cache = Path.join(context.directory, "gzip-upload-cache")

    nix!([
      "copy",
      "--from",
      Path.join(context.directory, "gzip-source"),
      "--to",
      "file://" <> cache <> "?compression=gzip",
      path
    ])

    filename = Path.join(cache, Narinfo.key(path))
    bytes = File.read!(filename)
    {:ok, info} = Narinfo.parse(bytes, Narinfo.key(path))
    url = if String.ends_with?(info.url, ".gz"), do: info.url, else: info.url <> ".gz"
    if url != info.url, do: File.rename!(Path.join(cache, info.url), Path.join(cache, url))
    File.write!(filename, String.replace(bytes, "URL: #{info.url}\n", "URL: #{url}\n"))
    :ok = WorkStore.open_run(context.store, "gzip", [], [], 128 * 1024)
    transfer = attach(context, "gzip", "gzip")
    assert upload(transfer, path, cache) == 200
    assert {:ok, [^path]} = WorkStore.paths(context.store, "gzip")
    assert File.read!(context.options[:root] <> path) == "gzip payload"
    assert :ok = WorkStore.detach(transfer)
  end

  test "run-close and GC racing an in-flight partial NAR cannot publish or strand staging",
       context do
    {path, cache} = exported(context.directory, "partial", "a partial compressed upload")

    {:ok, info} =
      Narinfo.parse(File.read!(Path.join(cache, Narinfo.key(path))), Narinfo.key(path))

    nar = File.read!(Path.join(cache, info.url))
    :ok = WorkStore.open_run(context.store, "partial", [], [], 128 * 1024)
    transfer = attach(context, "partial", "partial")
    {:ok, _, _, stage, _} = Garden.WorkStore.Service.context(transfer.service)

    {:ok, socket} =
      :gen_tcp.connect(
        {:local, String.to_charlist(List.last(transfer.sockets))},
        0,
        [:binary, active: false],
        5000
      )

    :ok =
      :gen_tcp.send(socket, [
        "PUT /",
        info.url,
        " HTTP/1.1\r\nHost: local\r\nContent-Length: ",
        Integer.to_string(byte_size(nar)),
        "\r\n\r\n",
        binary_part(nar, 0, div(byte_size(nar), 2))
      ])

    assert await_upload(stage, System.monotonic_time(:millisecond) + 5000)
    closing = Task.async(fn -> WorkStore.close_run(context.store, "partial") end)
    collecting = Task.async(fn -> WorkStore.gc(context.store) end)
    assert Task.await(closing, 10_000) == :ok
    assert Task.await(collecting, 10_000) == :ok
    :gen_tcp.close(socket)
    assert :ok = WorkStore.detach(transfer)
    refute File.exists?(stage)
    refute File.exists?(context.options[:root] <> path)
    assert {:error, :run_closed} = WorkStore.paths(context.store, "partial")
    refute_receive {:work_store_paths, "partial", [_ | _]}
  end

  defp await_upload(stage, deadline) do
    {:ok, files} = File.ls(stage)

    cond do
      Enum.any?(files, &String.ends_with?(&1, ".upload")) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        await_upload(stage, deadline)
    end
  end

  defp attach(context, sid, id) do
    directory = Path.join(context.directory, "vm-" <> id)
    File.mkdir_p!(directory)
    {:ok, transfer} = WorkStore.attach(context.store, sid, id, directory, self(), 30_000)
    transfer
  end

  defp exported(directory, name, bytes) do
    source = Path.join(directory, name <> "-source")
    file = Path.join(directory, name)
    File.write!(file, bytes)
    path = nix!(["store", "add-file", "--store", source, file]) |> String.trim()
    cache = Path.join(directory, name <> "-cache")
    nix!(["copy", "--from", source, "--to", "file://" <> cache <> "?compression=xz", path])
    {path, cache}
  end

  defp nix!(args) do
    {output, 0} =
      System.cmd(
        System.find_executable("nix"),
        ["--extra-experimental-features", "nix-command" | args],
        stderr_to_stdout: false
      )

    output
  end

  defp upload(transfer, path, cache) do
    info_bytes = File.read!(Path.join(cache, Narinfo.key(path)))
    {:ok, info} = Narinfo.parse(info_bytes, Narinfo.key(path))
    {200, _} = request(transfer, :write, "PUT", info.url, File.read!(Path.join(cache, info.url)))
    {status, _} = request(transfer, :write, "PUT", Narinfo.key(path), info_bytes)
    status
  end

  defp request(transfer, mode, method, key, body \\ "") do
    path = Enum.at(transfer.sockets, if(mode == :read, do: 0, else: 1))

    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 5000)

    :ok =
      :gen_tcp.send(socket, [
        method,
        " /",
        key,
        " HTTP/1.1\r\nHost: local\r\nConnection: close\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    response = receive_response(socket, [])
    [headers, body] = String.split(response, "\r\n\r\n", parts: 2)
    [_, status | _] = String.split(headers, " ", parts: 3)
    {String.to_integer(status), body}
  end

  defp receive_response(socket, bytes) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, chunk} -> receive_response(socket, [chunk | bytes])
      {:error, :closed} -> bytes |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
