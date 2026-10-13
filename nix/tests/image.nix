{
  pkgs,
  flake,
  beamPackages,
}:
let
  system = "x86_64-linux";
  garden = flake.packages.${system}.garden;
  stock = flake.lib.mkImage { inherit system; };
  probe = pkgs.writeText "image-probe.py" ''
    import json, os, sys, time
    mode = sys.argv[1]
    if mode == "exact":
        assert sys.argv[2:] == ["space argument", "", "literal;$x"]
        assert dict(os.environ) == {"ONLY": "provided", "PYTHONCOERCECLOCALE": "0"}
        assert json.load(sys.stdin) == {"message": "stdin", "number": 7}
        sys.stdout.buffer.write(b"out\x00\xff\n")
        sys.stderr.buffer.write(b"err\x00\xfe\n")
        sys.exit(23)
    if mode == "write":
        assert os.statvfs("/").f_flag & os.ST_RDONLY
        with open("/sys/class/net/lo/flags") as flags:
            assert int(flags.read().strip(), 16) & 0x1
        assert not any(os.path.exists("/sys/class/net/" + interface + "/device")
                       for interface in os.listdir("/sys/class/net"))
        with open("/etc/sower/image-marker") as marker:
            assert marker.read() == "sower-custom-image\n"
        with open("/var/image-service-ready") as ready:
            assert ready.read() == "service-ready\n"
        assert not os.path.exists("/var/image-private")
        open("/var/image-private", "w").write(sys.argv[2])
        import subprocess
        subprocess.run(["/run/current-system/sw/bin/nix-store", "--query", "--requisites", "/run/current-system"], check=True, stdout=subprocess.DEVNULL)
        path = subprocess.check_output(["/run/current-system/sw/bin/nix-store", "--add", "/var/image-private"]).decode().strip()
        assert open(path).read() == sys.argv[2]
        time.sleep(float(sys.argv[3]))
        assert open("/var/image-private").read() == sys.argv[2]
        sys.stdout.write("isolated:" + sys.argv[2])
    if mode == "signal":
        import signal
        os.kill(os.getpid(), signal.SIGTERM)
    if mode == "block":
        while True:
            sys.stdout.buffer.write(b"x" * 65536)
            sys.stdout.buffer.flush()
  '';
  custom = flake.lib.mkImage {
    inherit system;
    modules = [
      ({ ... }: {
        environment.systemPackages = [ pkgs.python3 ];
        environment.etc."sower/probe.py".source = probe;
        environment.etc."sower/image-marker".text = "sower-custom-image\n";
        systemd.services.image-ready = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = "printf 'service-ready\\n' > /var/image-service-ready";
        };
      })
    ];
  };
  scenario = pkgs.writeText "image-scenario.exs" ''
    {:ok, _} = Application.ensure_all_started(:cloud_hypervisor)
    alias Garden.Image
    alias Garden.VM
    {:ok, stock} = Image.load("${stock}")
    {:ok, custom} = Image.load("${custom}")
    root = "/tmp/image-scenarios"
    File.mkdir!(root)
    opts = [resource_directory: root, deadline_ms: 90_000, scratch_bytes: 1024 * 1024 * 1024]
    command = fn mode, args ->
      %VM.Command{path: "${pkgs.python3}/bin/python3", args: ["/etc/sower/probe.py", mode | args],
        env: %{"ONLY" => "provided", "PYTHONCOERCECLOCALE" => "0"},
        stdin: %{"message" => "stdin", "number" => 7}}
    end
    ensure = fn condition -> if not condition, do: raise("image lifecycle assertion failed") end
    clean = fn -> ensure.(File.ls!(root) == []) end
    parent = self()
    output = fn stream, bytes -> send(parent, {stream, bytes}) end
    {:ok, missing_vmm} = VM.start_link(opts ++ [image: stock,
      command: %VM.Command{path: "/run/current-system/sw/bin/true"},
      hypervisor: "/nonexistent/sower-hypervisor"])
    {:error, {:vmm_failed, {:startup, startup_message}}} = VM.await(missing_vmm)
    ensure.(is_binary(startup_message))
    missing_status = VM.status(missing_vmm)
    ensure.(missing_status.cleanup == :ok and missing_status.os_pid == nil)
    ensure.(is_pid(missing_status.vmm) and not Process.alive?(missing_status.vmm))
    GenServer.stop(missing_vmm)
    clean.()
    {:ok, failed_formatter} = VM.start_link(opts ++ [image: stock,
      command: %VM.Command{path: "/run/current-system/sw/bin/true"},
      mkfs: "${pkgs.coreutils}/bin/false"])
    {:error, {:mkfs, {:shutdown, {:exit_status, 1}}}} = VM.await(failed_formatter)
    formatter_status = VM.status(failed_formatter)
    ensure.(formatter_status.cleanup == :ok and formatter_status.vmm == nil)
    GenServer.stop(failed_formatter)
    clean.()
    {:ok, result} = VM.run(stock, %VM.Command{path: "/run/current-system/sw/bin/bash",
      args: ["-c", "printf stock-command"]}, Keyword.put(opts, :on_output, output))
    ensure.(result.code == 0)
    receive do {:stdout, "stock-command"} -> :ok after 1000 -> raise "missing stock output" end
    clean.()
    {:ok, cli_result} = Garden.VM.CLI.main(["${stock}", "--path",
      "/run/current-system/sw/bin/bash", "--argv", "[\"-c\",\"printf cli-command\"]",
      "--scratch-mib", "1024", "--deadline-ms", "90000"])
    ensure.(cli_result.code == 0)
    {:ok, result} = VM.run(custom, command.("exact", ["space argument", "", "literal;$x"]),
      Keyword.put(opts, :on_output, output))
    ensure.(result.code == 23)
    collect = fn collect, acc ->
      receive do
        {stream, bytes} when stream in [:stdout, :stderr] ->
          collect.(collect, Map.update(acc, stream, bytes, &(&1 <> bytes)))
      after 0 -> acc end
    end
    ensure.(collect.(collect, %{}) == %{stdout: <<"out", 0, 255, 10>>, stderr: <<"err", 0, 254, 10>>})
    clean.()
    {:ok, a} = VM.start_link(opts ++ [image: custom, command: command.("write", ["a", "2"])])
    {:ok, b} = VM.start_link(opts ++ [image: custom, command: command.("write", ["b", "0"])])
    {:ok, ra} = VM.await(a)
    {:ok, rb} = VM.await(b)
    ensure.(ra.code == 0 and rb.code == 0)
    GenServer.stop(a)
    GenServer.stop(b)
    clean.()
    {:ok, fresh} = VM.run(custom, command.("write", ["fresh", "0"]), opts)
    ensure.(fresh.code == 0)
    clean.()
    wait = fn wait, execution ->
      status = VM.status(execution)
      if status.phase == :running, do: status, else: (Process.sleep(20); wait.(wait, execution))
    end
    blocked = fn _, _ -> receive do :never -> :ok end end
    drain = fn _, _ -> :ok end
    {:ok, timed} = VM.start_link(Keyword.merge(opts,
      image: custom, command: command.("block", []), on_output: blocked, deadline_ms: 30_000))
    {:error, :timeout} = VM.await(timed)
    GenServer.stop(timed)
    clean.()
    {:ok, cancelled} = VM.start_link(opts ++ [image: custom, command: command.("block", []), on_output: blocked])
    wait.(wait, cancelled)
    :ok = VM.cancel(cancelled)
    {:error, :cancelled} = VM.await(cancelled)
    GenServer.stop(cancelled)
    clean.()
    owner = spawn(fn -> receive do :never -> :ok end end)
    {:ok, orphan} = VM.start_link(opts ++ [image: custom, command: command.("block", []),
      owner: owner, on_output: drain])
    wait.(wait, orphan)
    Process.exit(owner, :kill)
    {:error, :owner_down} = VM.await(orphan)
    GenServer.stop(orphan)
    clean.()
    {:ok, dead} = VM.start_link(opts ++ [image: custom, command: command.("block", []),
      on_output: drain])
    status = wait.(wait, dead)
    {_, 0} = System.cmd("kill", ["--signal", "KILL", Integer.to_string(status.os_pid)])
    {:error, _} = VM.await(dead)
    ensure.(VM.status(dead).cleanup == :ok)
    GenServer.stop(dead)
    clean.()
    {:ok, severed} = VM.start_link(opts ++ [image: custom, command: command.("block", []),
      on_output: drain])
    status = wait.(wait, severed)
    Process.unlink(severed)
    Process.exit(severed, :kill)
    deadline = System.monotonic_time(:millisecond) + 15_000
    reclaimed = fn reclaimed ->
      if File.exists?(status.directory) do
        ensure.(System.monotonic_time(:millisecond) < deadline)
        Process.sleep(50)
        reclaimed.(reclaimed)
      end
    end
    reclaimed.(reclaimed)
    clean.()
    {:ok, retained} = VM.start_link(opts ++ [image: custom, command: command.("block", [])])
    status = wait.(wait, retained)
    unexpected = Path.join(status.directory, "unowned")
    File.write!(unexpected, "retain me")
    :ok = VM.cancel(retained)
    {:error, {:cleanup_unconfirmed, {:error, :cancelled},
      {:error, {:unexpected_files, ["unowned"]}}, directory}} = VM.await(retained)
    ensure.(directory == status.directory and File.read!(unexpected) == "retain me")
    ensure.(File.exists?(Path.join(directory, "scratch.ext4")))
    GenServer.stop(retained)
    Enum.each(["unowned", "scratch.ext4", "serial.log"], fn name ->
      :ok = File.rm(Path.join(directory, name))
    end)
    :ok = File.rmdir(directory)
    clean.()
    alias Garden.VM.Manager
    eventually = fn eventually, predicate, deadline ->
      if predicate.() do
        :ok
      else
        ensure.(System.monotonic_time(:millisecond) < deadline)
        Process.sleep(20)
        eventually.(eventually, predicate, deadline)
      end
    end
    until = fn predicate ->
      eventually.(eventually, predicate, System.monotonic_time(:millisecond) + 30_000)
    end
    manager_opts = Keyword.merge(opts,
      owner: self(), image: custom, cpus: 1, memory: 512 * 1024 * 1024,
      command: command.("block", []), on_output: drain)
    managed_wait = fn id ->
      deadline = System.monotonic_time(:millisecond) + 30_000
      until.(fn ->
        case Manager.status(id) do
          {:ok, status} ->
            if status.phase in [:finished, :retained] or
               System.monotonic_time(:millisecond) >= deadline do
              serial = if status.directory, do: File.read(Path.join(status.directory, "serial.log"))
              raise "managed VM did not become ready: #{inspect(status)} serial=#{inspect(serial)}"
            end
            status.phase == :running
          _ -> false
        end
      end)
      {:ok, status} = Manager.status(id)
      status
    end
    os_gone = fn os_pid ->
      until.(fn -> not File.exists?("/proc/#{os_pid}") end)
    end
    retired = fn execution ->
      until.(fn -> not Process.alive?(execution) end)
    end
    budgets = [vms: 2, cpus: 2, memory: 1024 * 1024 * 1024,
      scratch_bytes: 2 * 1024 * 1024 * 1024]
    start_manager = fn overrides ->
      {:ok, supervisor} = VM.Supervisor.start_link(
        Keyword.merge([budgets: budgets, result_limit: 2, shutdown_ms: 15_000], overrides))
      Process.unlink(supervisor)
      supervisor
    end
    controller = fn id ->
      {:ok, status} = Manager.status(id)
      status.execution
    end
    managed_ids = :ets.new(:managed_ids, [:set, :public])
    start_with_output = fn options ->
      token = make_ref()
      callback = fn stream, bytes ->
        until.(fn -> :ets.member(managed_ids, token) end)
        [{^token, id}] = :ets.lookup(managed_ids, token)
        send(parent, {:managed_output, id, stream, bytes})
      end
      {:ok, id} = Manager.start(Keyword.put(options, :on_output, callback))
      :ets.insert(managed_ids, {token, id})
      {:ok, id}
    end
    supervisor = start_manager.([])
    for {dimension, excessive} <- [cpus: 3, memory: 2 * 1024 * 1024 * 1024,
                                  scratch_bytes: 3 * 1024 * 1024 * 1024] do
      {:error, {:request_exceeds_capacity, ^dimension}} =
        Manager.start(Keyword.put(manager_opts, dimension, excessive))
      clean.()
      ensure.(DynamicSupervisor.count_children(Garden.VM.ExecutionSupervisor).active == 0)
    end
    {:error, :not_found} = Manager.status("not-an-execution")
    {:error, :not_found} = Manager.await("not-an-execution")
    {:error, :not_found} = Manager.cancel("not-an-execution")
    {:ok, exact_id} = start_with_output.(Keyword.put(manager_opts,
      :command, command.("exact", ["space argument", "", "literal;$x"])))
    exact_controller = controller.(exact_id)
    {:ok, exact_result} = Manager.await(exact_id)
    ensure.(exact_result.code == 23)
    {:ok, exact_status} = Manager.status(exact_id)
    ensure.(exact_status.phase == :finished and exact_status.cleanup == :ok)
    ensure.(exact_status.result == {:ok, exact_result})
    ensure.(exact_status.execution_id == exact_id and exact_status.execution == exact_controller)
    retired.(exact_controller)
    managed_collect = fn collect, id, acc ->
      receive do
        {:managed_output, ^id, stream, bytes} ->
          collect.(collect, id, Map.update(acc, stream, bytes, &(&1 <> bytes)))
      after 0 -> acc end
    end
    ensure.(managed_collect.(managed_collect, exact_id, %{}) ==
      %{stdout: <<"out", 0, 255, 10>>, stderr: <<"err", 0, 254, 10>>})
    clean.()
    {:ok, signal_id} = Manager.start(Keyword.put(manager_opts, :command, command.("signal", [])))
    {:ok, signal_result} = Manager.await(signal_id)
    ensure.(signal_result.code == nil and signal_result.signal == 15)
    {:ok, signal_status} = Manager.status(signal_id)
    ensure.(signal_status.result == {:ok, signal_result} and signal_status.cleanup == :ok)
    clean.()
    {:ok, a_id} = start_with_output.(Keyword.put(manager_opts,
      :command, command.("write", ["managed-a", "30"])))
    {:ok, b_id} = start_with_output.(Keyword.put(manager_opts,
      :command, command.("write", ["managed-b", "30"])))
    ensure.(a_id != b_id)
    a_status = managed_wait.(a_id)
    b_status = managed_wait.(b_id)
    ensure.(a_status.directory != b_status.directory and a_status.os_pid != b_status.os_pid)
    ensure.(a_status.execution_id == a_id and b_status.execution_id == b_id)
    {:ok, listed} = Manager.list()
    running_ids = for status <- listed, status.phase == :running, do: status.execution_id
    ensure.(running_ids == [a_id, b_id])
    a_socket_directory = CloudHypervisor.Process.status(a_status.vmm).directory
    b_socket_directory = CloudHypervisor.Process.status(b_status.vmm).directory
    ensure.(a_socket_directory != b_socket_directory)
    ensure.(File.exists?(Path.join(a_status.directory, "scratch.ext4")))
    ensure.(File.exists?(Path.join(b_status.directory, "scratch.ext4")))
    allocated = Enum.sort(File.ls!(root))
    {:error, {:capacity_exhausted, :vms}} = Manager.start(manager_opts)
    ensure.(Enum.sort(File.ls!(root)) == allocated)
    {:ok, a_result} = Manager.await(a_id)
    {:ok, b_result} = Manager.await(b_id)
    ensure.(a_result.code == 0 and b_result.code == 0)
    ensure.(managed_collect.(managed_collect, a_id, %{}) == %{stdout: "isolated:managed-a"})
    ensure.(managed_collect.(managed_collect, b_id, %{}) == %{stdout: "isolated:managed-b"})
    ensure.(not File.exists?(a_socket_directory) and not File.exists?(b_socket_directory))
    {:error, :not_found} = Manager.status(exact_id)
    {:error, :not_found} = Manager.status(signal_id)
    until.(fn -> DynamicSupervisor.count_children(Garden.VM.ExecutionSupervisor).active == 0 end)
    clean.()
    :ok = Manager.shutdown()
    {:error, :draining} = Manager.start(manager_opts)
    :ok = Supervisor.stop(supervisor, :normal, :infinity)
    for dimension <- [:cpus, :memory, :scratch_bytes] do
      supervisor = start_manager.(budgets: Keyword.put(budgets, :vms, 3))
      {:ok, held_id} = Manager.start(Keyword.put(manager_opts, dimension, budgets[dimension]))
      held_status = managed_wait.(held_id)
      allocated = Enum.sort(File.ls!(root))
      {:error, {:capacity_exhausted, ^dimension}} = Manager.start(manager_opts)
      ensure.(Enum.sort(File.ls!(root)) == allocated)
      :ok = Manager.cancel(held_id)
      {:error, :cancelled} = Manager.await(held_id)
      os_gone.(held_status.os_pid)
      clean.()
      :ok = Manager.shutdown()
      :ok = Supervisor.stop(supervisor, :normal, :infinity)
    end
    supervisor = start_manager.([])
    blocked_managed = fn stream, bytes ->
      send(parent, {:output_blocked, self(), stream, byte_size(bytes)})
      receive do :never -> :ok end
    end
    {:ok, cancelled_id} = Manager.start(Keyword.put(manager_opts, :on_output, blocked_managed))
    cancelled_status = managed_wait.(cancelled_id)
    receive do {:output_blocked, _, _, size} when size > 0 -> :ok
      after 10_000 -> raise "managed output did not block" end
    :ok = Manager.cancel(cancelled_id)
    {:error, :cancelled} = Manager.await(cancelled_id)
    os_gone.(cancelled_status.os_pid)
    clean.()
    {:ok, deadline_id} = Manager.start(Keyword.merge(manager_opts,
      on_output: blocked_managed, deadline_ms: 30_000))
    deadline_status = managed_wait.(deadline_id)
    receive do {:output_blocked, _, _, size} when size > 0 -> :ok
      after 10_000 -> raise "deadline output did not block" end
    {:error, :timeout} = Manager.await(deadline_id)
    os_gone.(deadline_status.os_pid)
    clean.()
    for death <- [:owner, :controller, :vmm] do
      owner = spawn(fn -> receive do :never -> :ok end end)
      {:ok, id} = Manager.start(Keyword.put(manager_opts, :owner, owner))
      execution = controller.(id)
      status = managed_wait.(id)
      case death do
        :owner -> Process.exit(owner, :kill)
        :controller -> Process.exit(execution, :kill)
        :vmm -> {_, 0} = System.cmd("kill", ["--signal", "KILL", Integer.to_string(status.os_pid)])
      end
      case {death, Manager.await(id)} do
        {:vmm, {:error, _}} -> :ok
        {_, {:error, :owner_down}} -> :ok
        other -> raise "unexpected managed death result: #{inspect(other)}"
      end
      {:ok, terminal} = Manager.status(id)
      ensure.(terminal.cleanup == :ok and terminal.phase == :finished)
      retired.(execution)
      os_gone.(status.os_pid)
      Process.exit(owner, :kill)
      clean.()
    end
    :ok = Manager.shutdown()
    :ok = Supervisor.stop(supervisor, :normal, :infinity)
    for subtree <- [Garden.VM.Manager, Garden.VM.ExecutionSupervisor] do
      supervisor = start_manager.([])
      {:ok, first_id} = Manager.start(manager_opts)
      {:ok, second_id} = Manager.start(manager_opts)
      statuses = Enum.map([first_id, second_id], managed_wait)
      old_subtree = Process.whereis(subtree)
      Process.exit(old_subtree, :kill)
      Enum.each(statuses, fn status -> os_gone.(status.os_pid) end)
      until.(fn ->
        new_subtree = Process.whereis(subtree)
        new_subtree != nil and new_subtree != old_subtree and
          Process.whereis(Garden.VM.Manager) != nil
      end)
      until.(fn -> DynamicSupervisor.count_children(Garden.VM.ExecutionSupervisor).active == 0 end)
      Enum.each([first_id, second_id], fn id ->
        {:error, :owner_down} = Manager.await(id)
        {:ok, status} = Manager.status(id)
        ensure.(status.phase == :finished and status.cleanup == :ok)
      end)
      clean.()
      {:ok, fresh_id} = Manager.start(manager_opts)
      ensure.(fresh_id != first_id and fresh_id != second_id)
      fresh_status = managed_wait.(fresh_id)
      :ok = Manager.shutdown()
      {:error, :draining} = Manager.start(manager_opts)
      {:error, _} = Manager.await(fresh_id)
      os_gone.(fresh_status.os_pid)
      :ok = Supervisor.stop(supervisor, :normal, :infinity)
      clean.()
    end
    supervisor = start_manager.([])
    {:ok, killed_subtree_id} = Manager.start(manager_opts)
    killed_subtree_status = managed_wait.(killed_subtree_id)
    killed_subtree_socket_directory =
      CloudHypervisor.Process.status(killed_subtree_status.vmm).directory
    Process.exit(supervisor, :kill)
    until.(fn ->
      Enum.all?([Garden.VM.Supervisor, Garden.VM.Manager,
        Garden.VM.ExecutionSupervisor, Garden.VM.Ledger], fn name ->
        Process.whereis(name) == nil
      end)
    end)
    os_gone.(killed_subtree_status.os_pid)
    until.(fn -> not File.exists?(killed_subtree_status.directory) end)
    ensure.(not File.exists?(killed_subtree_socket_directory))
    supervisor = start_manager.([])
    {:error, :owner_down} = Manager.await(killed_subtree_id)
    {:ok, killed_subtree_terminal} = Manager.status(killed_subtree_id)
    ensure.(killed_subtree_terminal.phase == :finished and killed_subtree_terminal.cleanup == :ok)
    ensure.(DynamicSupervisor.count_children(Garden.VM.ExecutionSupervisor).active == 0)
    clean.()
    {:ok, after_subtree_id} = Manager.start(manager_opts)
    ensure.(after_subtree_id != killed_subtree_id)
    after_subtree_status = managed_wait.(after_subtree_id)
    :ok = Manager.shutdown()
    {:error, :cancelled} = Manager.await(after_subtree_id)
    os_gone.(after_subtree_status.os_pid)
    :ok = Supervisor.stop(supervisor, :normal, :infinity)
    clean.()
    supervisor = start_manager.([])
    {:ok, shutdown_id} = Manager.start(Keyword.put(manager_opts, :on_output, blocked_managed))
    shutdown_status = managed_wait.(shutdown_id)
    receive do {:output_blocked, _, _, size} when size > 0 -> :ok
      after 10_000 -> raise "shutdown output did not block" end
    :ok = Supervisor.stop(supervisor, :normal, :infinity)
    ensure.(Process.whereis(Garden.VM.Manager) == nil)
    os_gone.(shutdown_status.os_pid)
    clean.()
    config = Garden.Config.load(%{
      "state_directory" => "/tmp/image-garden-state",
      "admin_socket" => "/tmp/image-garden-admin.sock",
      "vm_capacity" => Map.new(Keyword.put(budgets, :vms, 1), fn {key, value} ->
        {Atom.to_string(key), value}
      end)
    }, skip_config_file: true)
    ensure.(config.endpoint == nil)
    {:ok, _} = Application.ensure_all_started(:garden)
    {:ok, garden_id} = Manager.start(Keyword.put(manager_opts, :on_output, blocked_managed))
    garden_status = managed_wait.(garden_id)
    receive do {:output_blocked, _, _, size} when size > 0 -> :ok
      after 10_000 -> raise "garden shutdown output did not block" end
    true = :erlang.suspend_process(garden_status.guard)
    spawn(fn -> :ok = Application.stop(:garden); send(parent, :garden_stopped) end)
    until.(fn ->
      case Manager.start(manager_opts) do
        {:error, :draining} -> true
        {:error, {:capacity_exhausted, :vms}} -> false
        other -> raise "admission opened during garden shutdown: #{inspect(other)}"
      end
    end)
    true = :erlang.resume_process(garden_status.guard)
    receive do :garden_stopped -> :ok after 30_000 -> raise "garden did not drain" end
    ensure.(Process.whereis(Garden.VM.Supervisor) == nil)
    ensure.(Process.whereis(Garden.VM.Manager) == nil)
    os_gone.(garden_status.os_pid)
    ensure.(not File.exists?(garden_status.directory))
    clean.()
    supervisor = start_manager.(budgets: Keyword.put(budgets, :vms, 1), result_limit: 1)
    {:ok, retained_id} = Manager.start(manager_opts)
    retained_controller = controller.(retained_id)
    retained_status = managed_wait.(retained_id)
    retained_file = Path.join(retained_status.directory, "unowned")
    File.write!(retained_file, "managed retention")
    :ok = Manager.cancel(retained_id)
    {:error, {:cleanup_unconfirmed, {:error, :cancelled},
      {:error, {:unexpected_files, ["unowned"]}}, retained_directory}} = Manager.await(retained_id)
    ensure.(retained_directory == retained_status.directory)
    retired.(retained_controller)
    {:ok, retained_status} = Manager.status(retained_id)
    ensure.(retained_status.phase == :retained and File.read!(retained_file) == "managed retention")
    ensure.(File.exists?(Path.join(retained_directory, "scratch.ext4")))
    {:error, {:capacity_exhausted, :vms}} = Manager.start(manager_opts)
    {:error, {:cleanup_incomplete, failures}} = Manager.shutdown()
    ensure.(Enum.any?(failures, fn {id, _, directory} ->
      id == retained_id and directory == retained_directory
    end))
    {:error, :draining} = Manager.start(manager_opts)
    :ok = Supervisor.stop(supervisor, :normal, :infinity)
    ensure.(File.read!(retained_file) == "managed retention")
    supervisor = start_manager.(budgets: Keyword.put(budgets, :vms, 1), result_limit: 1)
    {:ok, restarted_retained_status} = Manager.status(retained_id)
    ensure.(restarted_retained_status.phase == :retained)
    ensure.(restarted_retained_status.result == retained_status.result)
    ensure.(restarted_retained_status.directory == retained_directory)
    ensure.(File.read!(retained_file) == "managed retention")
    ensure.(DynamicSupervisor.count_children(Garden.VM.ExecutionSupervisor).active == 0)
    {:error, {:capacity_exhausted, :vms}} = Manager.start(manager_opts)
    {:error, {:cleanup_incomplete, _}} = Manager.shutdown()
    :ok = Supervisor.stop(supervisor, :normal, :infinity)
    Enum.each(["unowned", "scratch.ext4", "serial.log"], fn name ->
      :ok = File.rm(Path.join(retained_directory, name))
    end)
    :ok = File.rmdir(retained_directory)
    clean.()
    supervisor = start_manager.(budgets: Keyword.put(budgets, :vms, 1), result_limit: 1)
    {:ok, unreleased_status} = Manager.status(retained_id)
    ensure.(unreleased_status.phase == :retained and unreleased_status.result == retained_status.result)
    {:error, {:capacity_exhausted, :vms}} = Manager.start(manager_opts)
    {:error, {:cleanup_incomplete, _}} = Manager.shutdown()
    :ok = Supervisor.stop(supervisor, :normal, :infinity)
    clean.()
    :ets.delete(managed_ids)
    IO.puts("real image scenarios passed; ready_ms=#{result.ready_ms} elapsed_ms=#{result.elapsed_ms}")
  '';
  runner = pkgs.writeShellApplication {
    name = "image-scenario";
    runtimeInputs = [
      beamPackages.elixir
      pkgs.cloud-hypervisor
      pkgs.e2fsprogs
      pkgs.coreutils
      pkgs.findutils
      pkgs.procps
    ];
    text = ''
      args=()
      while IFS= read -r directory; do
        args+=(-pa "$directory")
      done < <(find ${garden} -type d -name ebin)
      exec elixir "''${args[@]}" ${scenario}
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "sower-image";
  nodes.machine = { ... }: {
    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];
    boot.extraModprobeConfig = ''
      options kvm_intel nested=1
      options kvm_amd nested=1
    '';
    virtualisation.qemu.options = [
      "-cpu host"
      "-enable-kvm"
    ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    virtualisation.additionalPaths = [
      stock
      custom
      garden
    ];
    environment.systemPackages = [ runner ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -c /dev/kvm")
    machine.succeed("image-scenario", timeout=1200)
    machine.succeed("test -z \"$(find /tmp/image-scenarios -mindepth 1 -print -quit)\"")
    machine.succeed("! pgrep --full '[c]loud-hypervisor'")
    machine.succeed("test -z \"$(find /tmp -maxdepth 1 -type d -name 'cloud-hypervisor-*' -print -quit)\"")
  '';
}
