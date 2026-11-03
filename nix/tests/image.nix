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
    if mode == "network-peer":
        import select, socket, subprocess
        addresses = json.loads(subprocess.check_output(["${pkgs.iproute2}/bin/ip", "--json", "address"]))
        address = next(a["local"] for i in addresses if i["ifname"] != "lo" for a in i["addr_info"] if a["family"] == "inet")
        datagram = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        datagram.bind(("0.0.0.0", 18080))
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("0.0.0.0", 443))
        listener.listen()
        print("peer-address=" + address, flush=True)
        ready, _, _ = select.select([datagram, listener], [], [], 60)
        assert not ready, "peer isolation breached: protected listener received traffic"
        print("peer-deliveries=0", flush=True)
    if mode == "network-attack":
        import socket, struct, subprocess
        socket.getaddrinfo("cache.nixos.org", 443, type=socket.SOCK_STREAM)
        [route] = json.loads(subprocess.check_output(["${pkgs.iproute2}/bin/ip", "--json", "route", "show", "default"]))
        interface = route["dev"]
        gateway = route["gateway"]
        neighbors = json.loads(subprocess.check_output(["${pkgs.iproute2}/bin/ip", "--json", "neigh", "show", "dev", interface]))
        gateway_mac = bytes.fromhex(next(n["lladdr"] for n in neighbors if n["dst"] == gateway).replace(":", ""))
        own_mac = bytes.fromhex(open("/sys/class/net/" + interface + "/address").read().strip().replace(":", ""))
        subprocess.run(["${pkgs.iproute2}/bin/ip", "neigh", "change", gateway, "dev", interface, "nud", "probe"], check=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            neighbors = json.loads(subprocess.check_output(["${pkgs.iproute2}/bin/ip", "--json", "neigh", "show", "dev", interface]))
            if any(n["dst"] == gateway and "REACHABLE" in n["state"] for n in neighbors):
                break
            if any(n["dst"] == gateway and "FAILED" in n["state"] for n in neighbors):
                raise AssertionError("gateway unicast ARP probe failed")
            time.sleep(0.05)
        else:
            raise AssertionError("gateway unicast ARP probe did not complete")
        for target in sys.argv[2:]:
            sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sender.sendto(b"sower-isolation-probe", (target, 18080))
            sender.close()
            try:
                connection = socket.create_connection((target, 443), timeout=2)
            except OSError:
                pass
            else:
                connection.close()
                raise AssertionError("protected TCP connection succeeded: " + target)
        try:
            connection = socket.create_connection(("8.8.4.4", 18080), timeout=2)
        except OSError:
            pass
        else:
            connection.close()
            raise AssertionError("DNAT widened the authorized transport port")
        # An otherwise public destination must not be reachable using a forged source.
        packet = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
        payload = b"sower-source-spoof"
        header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 28 + len(payload), 0, 0, 64, 17, 0,
                             socket.inet_aton("8.8.8.8"), socket.inet_aton("1.1.1.1"))
        packet.sendto(header + struct.pack("!HHHH", 18080, 53, 8 + len(payload), 0) + payload,
                      ("1.1.1.1", 53))
        packet.close()
        # AF_PACKET bypasses the guest's IPv6 stack (which may be absent).
        source = socket.inet_pton(socket.AF_INET6, "2001:4860:4860::8844")
        destination = socket.inet_pton(socket.AF_INET6, "2001:4860:4860::8888")
        udp = struct.pack("!HHHH", 18080, 18080, 8 + len(payload), 0) + payload
        pseudo = source + destination + struct.pack("!I3xB", len(udp), 17) + udp
        if len(pseudo) % 2:
            pseudo += b"\0"
        checksum = sum(struct.unpack("!%dH" % (len(pseudo) // 2), pseudo))
        while checksum >> 16:
            checksum = (checksum & 65535) + (checksum >> 16)
        udp = udp[:6] + struct.pack("!H", (~checksum & 65535) or 65535) + udp[8:]
        ethernet = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
        ethernet.bind((interface, 0))
        ethernet.send(gateway_mac + own_mac + b"\x86\xdd" +
                      struct.pack("!IHBB", 6 << 28, len(udp), 17, 64) + source + destination + udp)
        ethernet.close()
        print("protected TCP/UDP, source spoof, and IPv6 probes sent", flush=True)
    if mode == "signal":
        import signal
        os.kill(os.getpid(), signal.SIGTERM)
    if mode == "tree":
        import subprocess
        child = subprocess.Popen(["/run/current-system/sw/bin/sleep", "60"], start_new_session=True)
        open("/var/command-child", "w").write(str(child.pid))
        while True:
            sys.stdout.buffer.write(b"x" * 65536)
            sys.stdout.buffer.flush()
    if mode == "tree-gone":
        child = int(open("/var/command-child").read())
        assert not os.path.exists("/proc/" + str(child)), "command descendant survived"
        print("tree-reaped", flush=True)
    if mode == "block":
        while True:
            sys.stdout.buffer.write(b"x" * 65536)
            sys.stdout.buffer.flush()
  '';
  custom = flake.lib.mkImage {
    inherit system;
    modules = [
      ({ ... }: {
        environment.systemPackages = [
          pkgs.python3
          pkgs.curl
          pkgs.iproute2
        ];
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
  agentless = flake.lib.mkImage {
    inherit system;
    modules = [
      ({ ... }: {
        boot.initrd.systemd.targets.agentless = {
          unitConfig.DefaultDependencies = false;
          requires = [ "agentless-ready.service" ];
          after = [ "agentless-ready.service" ];
        };
        boot.initrd.systemd.services.agentless-ready = {
          unitConfig.DefaultDependencies = false;
          requires = [ "systemd-udevd.service" ];
          after = [ "systemd-udevd.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = "printf 'sower-agentless-userspace-ready\\n' > /dev/ttyS0";
        };
      })
    ];
  };
  scenario = pkgs.writeText "image-scenario.exs" ''
    alias Garden.Image
    alias VMManager, as: VM
    {:ok, stock} = Image.load("${stock}")
    {:ok, custom} = Image.load("${custom}")
    root = "/tmp/image-scenarios"
    File.mkdir_p!(root)
    Application.put_env(:vm_manager, :state_directory, "/tmp/image-manager-state")
    budgets = [vms: 2, cpus: 2, memory: 1024 * 1024 * 1024,
      scratch_bytes: 2 * 1024 * 1024 * 1024]
    Application.put_env(:vm_manager, :budgets, budgets)
    {:ok, _} = Application.ensure_all_started(:vm_manager)
    ensure = fn condition -> if not condition, do: raise("image lifecycle assertion failed") end
    until = fn predicate ->
      deadline = System.monotonic_time(:millisecond) + 30_000
      wait = fn wait ->
        unless predicate.() do
          ensure.(System.monotonic_time(:millisecond) < deadline)
          Process.sleep(20)
          wait.(wait)
        end
      end
      wait.(wait)
    end
    clean = fn -> ensure.(File.ls!(root) == []) end
    parent = self()
    output = fn stream, bytes -> send(parent, {stream, bytes}) end
    collect = fn collect, acc ->
      receive do
        {stream, bytes} when stream in [:stdout, :stderr] ->
          collect.(collect, Map.update(acc, stream, bytes, &(&1 <> bytes)))
      after 0 -> acc end
    end
    config = fn image, overrides ->
      id = "image-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
      Image.vm_config(image, id, Keyword.merge(
        [runtime_directory: root, boot_deadline_ms: 90_000,
         scratch_bytes: 1024 * 1024 * 1024], overrides))
    end
    define = fn image, overrides ->
      cfg = config.(image, overrides)
      {:ok, id} = VM.define(cfg)
      id
    end
    boot = fn image, overrides ->
      id = define.(image, overrides)
      :ok = VM.start(id)
      {:ok, _} = VM.await_ready(id)
      id
    end
    retire = fn id ->
      :ok = VM.stop(id)
      {:ok, status} = VM.status(id)
      ensure.(status.cleanup == :ok)
      :ok = VM.remove(id)
    end
    shell = fn script ->
      %VM.Command{path: "/run/current-system/sw/bin/bash", args: ["-c", script]}
    end
    command = fn mode, args ->
      %VM.Command{path: "${pkgs.python3}/bin/python3",
        args: ["/etc/sower/probe.py", mode | args],
        env: %{"ONLY" => "provided", "PYTHONCOERCECLOCALE" => "0"},
        stdin: %{"message" => "stdin", "number" => 7}}
    end
    run = fn image, command, options ->
      id = boot.(image, [])
      {:ok, handle} = VM.execute(id, command, options)
      result = VM.await_command(handle)
      retire.(id)
      clean.()
      result
    end
    external_disk = "/tmp/image-agentless.raw"
    File.write!(external_disk, "external-disk-contents")
    {_, 0} = System.cmd("truncate", ["--size", "16M", external_disk])
    agentless_config = %VM.Config{
      id: "agentless-image",
      kernel: "${agentless}/kernel",
      initrd: "${agentless}/initrd",
      cmdline: "console=ttyS0 rd.systemd.unit=agentless.target",
      serial: %CloudHypervisor.Config.Output{mode: :file, file: "serial.log"},
      disks: [%CloudHypervisor.Config.Disk{
        path: external_disk, readonly: false, image_type: :raw
      }],
      runtime_directory: root,
      mkfs: "${pkgs.coreutils}/bin/false"
    }
    {:ok, "agentless-image"} = VM.define(agentless_config)
    :ok = VM.subscribe("agentless-image")
    :ok = VM.start("agentless-image")
    {:ok, %VM.Status{running: true, phase: :running} = agentless} =
      VM.await_running("agentless-image")
    serial_ready = fn status ->
      until.(fn ->
        case File.read(Path.join(status.directory, "serial.log")) do
          {:ok, log} -> String.contains?(log, "sower-agentless-userspace-ready")
          {:error, _} -> false
        end
      end)
    end
    serial_ready.(agentless)
    receive_running = fn receive_running ->
      receive do
        {:vm_manager, "agentless-image", %VM.Status{running: true}} -> :ok
        {:vm_manager, "agentless-image", %VM.Status{}} -> receive_running.(receive_running)
      after 30_000 -> raise "missing agentless running notification"
      end
    end
    receive_running.(receive_running)
    {:error, :guest_agent_disabled} = VM.await_ready("agentless-image")
    {:error, :guest_agent_disabled} =
      VM.execute("agentless-image", %VM.Command{path: "/bin/true"})
    {:ok, listed} = VM.list()
    ensure.(Enum.any?(listed, &(&1.id == "agentless-image")))
    {:ok, observed} = VM.status("agentless-image")
    ensure.(observed.os_pid == agentless.os_pid)
    old_manager = Process.whereis(VMManager.Manager)
    Process.exit(old_manager, :kill)
    until.(fn ->
      manager = Process.whereis(VMManager.Manager)
      manager != nil and manager != old_manager
    end)
    {:ok, reconnected} = VM.await_running("agentless-image")
    ensure.(reconnected.os_pid == agentless.os_pid)
    :ok = Application.stop(:vm_manager)
    until.(fn -> not File.exists?("/proc/#{agentless.os_pid}") end)
    {:ok, _} = Application.ensure_all_started(:vm_manager)
    {:ok, restored_agentless} = VM.await_running("agentless-image")
    ensure.(restored_agentless.id == "agentless-image")
    ensure.(restored_agentless.os_pid != agentless.os_pid)
    serial_ready.(restored_agentless)
    retire.("agentless-image")
    ensure.(File.read!(external_disk) |> String.starts_with?("external-disk-contents"))
    clean.()
    {_, 0} = System.cmd("${pkgs.iproute2}/bin/ip", ["tuntap", "add", "dev", "sower-ext-test", "mode", "tap"])
    external_network = %VM.Network{
      ownership: :external,
      devices: [%CloudHypervisor.Config.Net{tap: "sower-ext-test", mac: "02:00:00:00:00:42"}]
    }
    network_config = %{agentless_config | id: "agentless-network", network: external_network}
    {:ok, "agentless-network"} = VM.define(network_config)
    :ok = VM.start("agentless-network")
    {:ok, %VM.Status{running: true}} = VM.await_running("agentless-network")
    retire.("agentless-network")
    {_, 0} = System.cmd("${pkgs.iproute2}/bin/ip", ["link", "show", "dev", "sower-ext-test"])
    failed_config = %{network_config | id: "agentless-network-failure", hypervisor: "/nonexistent/sower-hypervisor"}
    {:ok, "agentless-network-failure"} = VM.define(failed_config)
    :ok = VM.start("agentless-network-failure")
    {:error, _} = VM.await_running("agentless-network-failure")
    retire.("agentless-network-failure")
    {_, 0} = System.cmd("${pkgs.iproute2}/bin/ip", ["link", "show", "dev", "sower-ext-test"])
    {_, 0} = System.cmd("${pkgs.iproute2}/bin/ip", ["link", "delete", "dev", "sower-ext-test"])
    :ok = File.rm(external_disk)
    clean.()
    for {overrides, expected} <- [
      {[hypervisor: "/nonexistent/sower-hypervisor"], :vmm_failed},
      {[mkfs: "${pkgs.coreutils}/bin/false"], :mkfs}
    ] do
      id = define.(stock, overrides)
      :ok = VM.start(id)
      {:error, _} = VM.await_ready(id)
      until.(fn -> {:ok, status} = VM.status(id); status.cleanup == :ok end)
      {:ok, status} = VM.status(id)
      {:error, failure} = status.result
      ensure.(elem(failure, 0) == expected)
      retire.(id)
      clean.()
    end
    {:ok, %{code: 0}} = run.(stock, shell.("printf stock-command"), on_output: output)
    receive do {:stdout, "stock-command"} -> :ok after 1000 -> raise "missing stock output" end
    {:ok, %{code: 0}} = Garden.VM.CLI.main(["${stock}", "--path",
      "/run/current-system/sw/bin/bash", "--argv", "[\"-c\",\"printf cli-command\"]",
      "--scratch-mib", "1024", "--deadline-ms", "90000"])
    {:ok, %{code: 23}} = run.(custom,
      command.("exact", ["space argument", "", "literal;$x"]), on_output: output)
    ensure.(collect.(collect, %{}) == %{stdout: <<"out", 0, 255, 10>>, stderr: <<"err", 0, 254, 10>>})
    owned = boot.(custom, [])
    {:ok, idle} = VM.status(owned)
    ensure.(idle.phase == :ready and idle.persistent)
    Process.sleep(200)
    {:ok, current} = VM.status(owned)
    ensure.(current.os_pid == idle.os_pid and Process.alive?(idle.vmm))
    {:ok, first} = VM.execute(owned, shell.("printf persistent-value > /var/lifetime-value; exit 17"))
    {:ok, %{code: 17}} = VM.await_command(first)
    {:ok, second} = VM.execute(owned,
      shell.("test \"$(</var/lifetime-value)\" = persistent-value && printf 'out\\000\\377\\n' && printf 'err\\000\\376\\n' >&2"),
      on_output: output)
    {:ok, %{code: 0}} = VM.await_command(second)
    ensure.(collect.(collect, %{}) == %{stdout: <<"out", 0, 255, 10>>, stderr: <<"err", 0, 254, 10>>})
    {:ok, missing} = VM.execute(owned, %VM.Command{path: "/nonexistent/command"})
    {:error, {:guest, _}} = VM.await_command(missing)
    {:ok, signalled} = VM.execute(owned, command.("signal", []))
    {:ok, %{code: nil, signal: 15}} = VM.await_command(signalled)
    %VM.CommandStatus{phase: :finished, result: {:ok, %{code: 17}}} = VM.command_status(first)
    blocked = fn _, _ ->
      send(parent, :tree_output)
      receive do :never -> :ok end
    end
    for failure <- [:consumer, :cancel, :timeout, :caller] do
      callback = if failure == :consumer, do: fn _, _ -> exit(:normal) end, else: blocked
      options = [on_output: callback, deadline_ms: if(failure == :timeout, do: 2000, else: 60_000)]
      if failure == :caller do
        caller = spawn(fn ->
          {:ok, _} = VM.execute(owned, command.("tree", []), options)
          send(parent, :caller_command)
          receive do :never -> :ok end
        end)
        receive do :caller_command -> :ok after 1000 -> raise "missing caller handle" end
        receive do :tree_output -> :ok after 5000 -> raise "caller tree did not start" end
        Process.exit(caller, :kill)
      else
        {:ok, handle} = VM.execute(owned, command.("tree", []), options)
        if failure != :consumer do
          receive do :tree_output -> :ok after 5000 -> raise "tree did not start" end
          {:error, :busy} = VM.execute(owned, shell.("exit 99"))
        end
        expected = case failure do
          :consumer -> :output_consumer_down
          :cancel -> :ok = VM.cancel_command(handle); :cancelled
          :timeout -> :timeout
        end
        {:error, ^expected} = VM.await_command(handle)
      end
      retry = fn retry ->
        case VM.execute(owned, command.("tree-gone", []), on_output: output) do
          {:error, :busy} -> Process.sleep(20); retry.(retry)
          {:ok, handle} -> handle
        end
      end
      {:ok, %{code: 0}} = VM.await_command(retry.(retry))
      receive do {:stdout, "tree-reaped\n"} -> :ok after 1000 -> raise "missing process cleanup proof" end
    end
    {:ok, current} = VM.status(owned)
    ensure.(current.os_pid == idle.os_pid)
    {:ok, handle} = VM.execute(owned, command.("tree", []), on_output: blocked)
    receive do :tree_output -> :ok after 5000 -> raise "stop tree did not start" end
    :ok = VM.stop(owned)
    {:error, :vm_stopped} = VM.await_command(handle)
    {:error, :vm_unavailable} = VM.execute(owned, shell.("exit 0"))
    :ok = VM.remove(owned)
    clean.()
    boot_stop = define.(custom, [])
    :ok = VM.start(boot_stop)
    retire.(boot_stop)
    clean.()
    a = boot.(custom, [])
    b = boot.(custom, [])
    {:ok, a_status} = VM.status(a)
    {:ok, b_status} = VM.status(b)
    ensure.(a_status.directory != b_status.directory and a_status.os_pid != b_status.os_pid)
    {:ok, ah} = VM.execute(a, command.("write", ["a", "2"]), on_output: output)
    {:ok, bh} = VM.execute(b, command.("write", ["b", "0"]), on_output: output)
    {:ok, %{code: 0}} = VM.await_command(ah)
    {:ok, %{code: 0}} = VM.await_command(bh)
    ensure.(collect.(collect, %{}).stdout in ["isolated:aisolated:b", "isolated:bisolated:a"])
    {:ok, listed} = VM.list()
    ensure.(Enum.count(listed, &(&1.phase == :ready)) == 2)
    rejected = define.(custom, [])
    allocated = Enum.sort(File.ls!(root))
    {:error, {:capacity_exhausted, :vms}} = VM.start(rejected)
    ensure.(Enum.sort(File.ls!(root)) == allocated)
    :ok = VM.remove(rejected)
    retire.(a)
    retire.(b)
    clean.()
    for {dimension, excessive} <- [cpus: 3, memory: 2 * 1024 * 1024 * 1024,
                                  scratch_bytes: 3 * 1024 * 1024 * 1024] do
      id = define.(custom, [{dimension, excessive}])
      {:error, {:request_exceeds_capacity, ^dimension}} = VM.start(id)
      :ok = VM.remove(id)
      clean.()
    end
    for dimension <- [:cpus, :memory, :scratch_bytes] do
      held = boot.(custom, [{dimension, budgets[dimension]}])
      next = define.(custom, [])
      {:error, {:capacity_exhausted, ^dimension}} = VM.start(next)
      :ok = VM.remove(next)
      retire.(held)
      clean.()
    end
    {:error, :not_found} = VM.status("not-a-vm")
    {:error, :not_found} = VM.stop("not-a-vm")
    {:ok, %{code: 0}} = run.(custom, command.("write", ["fresh", "0"]), [])
    persistent_path = "/tmp/image-persistent.raw"
    {_, 0} = System.cmd("truncate", ["--size", "16M", persistent_path])
    persistent_config = config.(custom,
      disks: [%CloudHypervisor.Config.Disk{
        path: persistent_path, readonly: false, image_type: :raw
      }],
      persistent_disks: [persistent_path])
    {:ok, persistent_id} = VM.define(persistent_config)
    :ok = VM.start(persistent_id)
    {:ok, _} = VM.await_ready(persistent_id)
    {:ok, write_disk} = VM.execute(persistent_id, %VM.Command{
      path: "${pkgs.python3}/bin/python3",
      args: ["-c", "import os; disk = os.open('/dev/vdc', os.O_WRONLY); assert os.write(disk, b'sower-disk') == 10; os.fsync(disk); os.close(disk)"]
    })
    {:ok, %{code: 0}} = VM.await_command(write_disk)
    :ok = VM.stop(persistent_id)
    {:ok, stopped_disk} = VM.status(persistent_id)
    ensure.(stopped_disk.desired == :stopped and stopped_disk.cleanup == :ok)
    ensure.(File.regular?(persistent_path))
    clean.()
    :ok = VM.start(persistent_id)
    {:ok, _} = VM.await_ready(persistent_id)
    {:ok, read_disk} = VM.execute(persistent_id, %VM.Command{
      path: "${pkgs.python3}/bin/python3",
      args: ["-c", "disk = open('/dev/vdc', 'rb', buffering=0); assert disk.read(10) == b'sower-disk'; disk.close()"]
    })
    {:ok, %{code: 0}} = VM.await_command(read_disk)
    :ok = VM.stop(persistent_id)
    :ok = VM.remove(persistent_id)
    {:error, :not_found} = VM.status(persistent_id)
    ensure.(File.regular?(persistent_path))
    {:ok, ^persistent_id} = VM.define(persistent_config)
    :ok = VM.delete_storage(persistent_id)
    ensure.(not File.exists?(persistent_path))
    {:ok, _} = VM.status(persistent_id)
    :ok = VM.remove(persistent_id)
    clean.()
    durable = boot.(custom, [])
    {:ok, before} = VM.status(durable)
    old_manager = Process.whereis(VMManager.Manager)
    Process.exit(old_manager, :kill)
    until.(fn ->
      manager = Process.whereis(VMManager.Manager)
      manager != nil and manager != old_manager
    end)
    {:ok, after_manager} = VM.await_ready(durable)
    ensure.(after_manager.os_pid == before.os_pid)
    {:ok, handle} = VM.execute(durable, shell.("printf reconnect"))
    {:ok, %{code: 0}} = VM.await_command(handle)
    Garden.Config.load(%{"state_directory" => "/tmp/image-garden-state",
      "admin_socket" => "/tmp/image-garden-admin.sock"}, skip_config_file: true)
    {:ok, _} = Application.ensure_all_started(:garden)
    :ok = Application.stop(:garden)
    {:ok, after_garden} = VM.status(durable)
    ensure.(after_garden.os_pid == before.os_pid and after_garden.phase == :ready)
    :ok = Application.stop(:vm_manager)
    until.(fn -> not File.exists?("/proc/#{before.os_pid}") end)
    {:ok, _} = Application.ensure_all_started(:vm_manager)
    {:ok, restored} = VM.await_ready(durable)
    ensure.(restored.id == durable and restored.os_pid != before.os_pid)
    {:ok, handle} = VM.execute(durable, shell.("exit 0"))
    {:ok, %{code: 0}} = VM.await_command(handle)
    {_, 0} = System.cmd("kill", ["--signal", "KILL", Integer.to_string(restored.os_pid)])
    until.(fn -> {:ok, status} = VM.status(durable); status.phase in [:finished, :failed, :stopped] end)
    retire.(durable)
    clean.()
    retained = boot.(custom, [])
    {:ok, retained_status} = VM.status(retained)
    unexpected = Path.join(retained_status.directory, "unowned")
    File.write!(unexpected, "retain me")
    {:error, _} = VM.stop(retained)
    {:ok, retained_status} = VM.status(retained)
    ensure.(retained_status.cleanup != :ok and File.read!(unexpected) == "retain me")
    :ok = Application.stop(:vm_manager)
    {:ok, _} = Application.ensure_all_started(:vm_manager)
    {:ok, recovered} = VM.status(retained)
    ensure.(recovered.directory == retained_status.directory and recovered.cleanup != :ok)
    ensure.(File.read!(unexpected) == "retain me")
    :ok = Application.stop(:vm_manager)
    for name <- ["unowned", "scratch.ext4", "serial.log"] do
      :ok = File.rm(Path.join(recovered.directory, name))
    end
    :ok = File.rmdir(recovered.directory)
    clean.()
    IO.puts("real image scenarios passed")
  '';
  networkScenario = pkgs.writeText "image-network-scenario.exs" ''
    alias Garden.Image
    alias VMManager, as: VM
    alias VMManager, as: Manager
    {:ok, image} = Image.load("${custom}")
    root = System.get_env("SOWER_NETWORK_ROOT") || "/var/lib/sower-garden/image-network-scenarios"
    File.mkdir_p!(root)
    Application.put_env(:vm_manager, :state_directory, root <> "-manager-" <> System.pid())
    Application.put_env(:vm_manager, :budgets,
      [vms: 2, cpus: 2, memory: 5 * 1024 * 1024 * 1024,
       scratch_bytes: 8 * 1024 * 1024 * 1024])
    :ok = Application.load(:garden)
    Code.ensure_loaded!(Garden.VM.Network)
    Code.ensure_loaded!(Garden.ActivatorClient)
    {:ok, _} = Application.ensure_all_started(:vm_manager)
    parent = self()
    output = fn stream, bytes -> send(parent, {stream, bytes}) end
    options = [network: :full, runtime_directory: root, boot_deadline_ms: 90_000,
      cpus: 1, memory: 2 * 1024 * 1024 * 1024, scratch_bytes: 4 * 1024 * 1024 * 1024]
    define = fn overrides ->
      id = "network-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
      {:ok, ^id} = Manager.define(Image.vm_config(image, id, Keyword.merge(options, overrides)))
      id
    end
    boot = fn overrides ->
      id = define.(overrides)
      :ok = Manager.start(id)
      {:ok, _} = Manager.await_ready(id)
      id
    end
    retire = fn id ->
      :ok = Manager.stop(id)
      :ok = Manager.remove(id)
    end
    ensure = fn condition -> if not condition, do: raise("network lifecycle assertion failed") end
    collect = fn collect, acc ->
      receive do
        {:stdout, bytes} -> collect.(collect, acc <> bytes)
        {:stderr, bytes} -> IO.binwrite(:stderr, bytes); collect.(collect, acc)
      after 0 -> acc end
    end
    run = fn command ->
      id = boot.([])
      {:ok, handle} = Manager.execute(id, command, on_output: output, deadline_ms: 600_000)
      {:ok, result} = Manager.await_command(handle)
      stdout = collect.(collect, "")
      IO.binwrite(stdout)
      ensure.(result.code == 0)
      IO.puts("managed-exit=#{result.code}")
      retire.(id)
      stdout
    end
    blocked = %VM.Command{path: "/run/current-system/sw/bin/bash",
      args: ["-c", "echo network-live; exec curl --silent --show-error --connect-timeout 300 https://93.184.216.34"],
      env: %{"PATH" => "/run/current-system/sw/bin"}}
    live = fn overrides ->
      id = boot.([])
      {:ok, handle} = Manager.execute(id, blocked, Keyword.merge([on_output: output, deadline_ms: 600_000], overrides))
      receive do
        {:stdout, bytes} -> ensure.(bytes == "network-live\n")
        after 90_000 -> raise "network lifecycle guest did not start"
      end
      {:ok, status} = Manager.status(id)
      native = File.read!("/proc/#{status.os_pid}/status")
      [_, uid] = Regex.run(~r/^Uid:\s+(\d+)/m, native)
      [_, capabilities] = Regex.run(~r/^CapEff:\s+([0-9a-f]+)/m, native)
      ensure.(uid != "0" and String.to_integer(capabilities, 16) == 0)
      {id, handle}
    end
    if System.get_env("SOWER_NETWORK_EXPECT_FAILURE") do
      id = define.([])
      :ok = Manager.start(id)
      {:error, _} = Manager.await_ready(id)
      {:ok, status} = Manager.status(id)
      ensure.(status.cleanup != :ok and is_nil(status.vmm) and is_nil(status.os_pid))
      IO.puts("interrupted provision retained without launching a VMM")
      System.halt(0)
    end
    if hold = System.get_env("SOWER_NETWORK_HOLD") do
      id = boot.([])
      {:ok, _} = Manager.await_ready(id)
      {:ok, command} = Manager.execute(id, %VM.Command{path: "/run/current-system/sw/bin/true"})
      {:ok, %{code: 0}} = VM.await_command(command)
      {:ok, %{phase: :ready} = status} = Manager.status(id)
      File.write!(hold, Jason.encode!(%{beam: System.pid(), vmm: status.os_pid}))
      Process.sleep(:infinity)
    end
    owned_network = boot.([])
    {:ok, owned_status} = Manager.await_ready(owned_network)
    for _ <- 1..2 do
      {:ok, command} = Manager.execute(owned_network,
        %VM.Command{path: "/run/current-system/sw/bin/bash",
          args: ["-c", "getent hosts cache.nixos.org >/var/network-state"],
          env: %{"PATH" => "/run/current-system/sw/bin"}})
      {:ok, %{code: 0}} = VM.await_command(command)
      {:ok, status} = Manager.await_ready(owned_network)
      ensure.(status.phase == :ready and status.os_pid == owned_status.os_pid)
      ensure.(File.exists?(Path.join(status.directory, "scratch.ext4")))
    end
    retire.(owned_network)
    ensure.(not File.exists?(owned_status.directory))
    run.(%VM.Command{path: "/run/current-system/sw/bin/bash", args: ["-o", "errexit", "-o", "nounset", "-c", """
      curl --fail --location --max-time 120 https://github.com/NixOS/nix-installer/releases/download/2.35.2/nix-installer-x86_64-linux --output /tmp/nix-installer
      test "$(head --bytes 4 /tmp/nix-installer | od --address-radix=n --format=x1 | tr --delete ' \\n')" = 7f454c46
      nix config show --json | python3 -c 'import json,sys; c=json.load(sys.stdin); assert "https://cache.nixos.org/" in [v.rstrip("/") + "/" for v in c["substituters"]["value"]]; assert "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" in c["trusted-public-keys"]["value"]; assert c["require-sigs"]["value"] is True; print("signed-public-cache=verified")'
      printf 'release-bytes='
      wc --bytes < /tmp/nix-installer
      """], env: %{"PATH" => "/run/current-system/sw/bin"}})
    cowsay_ref = System.get_env("SOWER_COWSAY_REF") ||
      "github:nixos/nixpkgs/44a91898084f46797b5fac650c7e8c9ac38c43d4#cowsay"
    cowsay = run.(%VM.Command{path: "/run/current-system/sw/bin/nix",
      args: ["run", cowsay_ref,
        "--", "hello from sower"], env: %{"PATH" => "/run/current-system/sw/bin"}})
    ensure.(cowsay =~ "< hello from sower >")
    peer = boot.([])
    {:ok, peer_handle} = Manager.execute(peer,
      %VM.Command{path: "${pkgs.python3}/bin/python3",
        args: ["/etc/sower/probe.py", "network-peer"]},
      deadline_ms: 600_000,
      on_output: fn stream, bytes -> send(parent, {:peer, stream, bytes}) end)
    peer_address = receive do
      {:peer, :stdout, bytes} ->
        ["peer-address=" <> address] = String.split(bytes, "\n", trim: true)
        String.trim(address)
      after 90_000 -> raise "peer listener did not become ready"
    end
    attack = run.(%VM.Command{path: "${pkgs.python3}/bin/python3",
      args: ["/etc/sower/probe.py", "network-attack",
        "127.0.0.1", "192.168.50.1", "169.254.169.254", "93.184.216.34", peer_address]})
    ensure.(attack =~ "probes sent")
    {:ok, peer_result} = Manager.await_command(peer_handle)
    ensure.(peer_result.code == 0)
    receive do
      {:peer, :stdout, bytes} -> ensure.(bytes == "peer-deliveries=0\n")
      after 5_000 -> raise "missing peer delivery observation"
    end
    retire.(peer)
    {cancelled, cancelled_handle} = live.([])
    :ok = Manager.cancel_command(cancelled_handle)
    {:error, :cancelled} = Manager.await_command(cancelled_handle)
    retire.(cancelled)
    {timed, timed_handle} = live.(deadline_ms: 30_000)
    {:error, :timeout} = Manager.await_command(timed_handle)
    retire.(timed)
    orphan = boot.([])
    caller = spawn(fn ->
      {:ok, _} = Manager.execute(orphan, blocked, on_output: output, deadline_ms: 600_000)
      send(parent, :orphan_started)
      receive do :never -> :ok end
    end)
    receive do :orphan_started -> :ok after 1000 -> raise "missing orphan caller" end
    receive do {:stdout, "network-live\n"} -> :ok after 90_000 -> raise "missing orphan output" end
    Process.exit(caller, :kill)
    {:ok, _} = Manager.await_ready(orphan)
    retire.(orphan)
    {crashed, crashed_handle} = live.([])
    {:ok, crashed_status} = Manager.status(crashed)
    {_, 0} = System.cmd("kill", ["--signal", "KILL", Integer.to_string(crashed_status.os_pid)])
    {:error, _} = Manager.await_command(crashed_handle)
    retire.(crashed)
    {retired, retired_handle} = live.([])
    {:ok, retired_status} = Manager.status(retired)
    :ok = Manager.subscribe(retired)
    Process.exit(retired_status.execution, :kill)
    {:error, _} = Manager.await_command(retired_handle)
    receive do
      {:vm_manager, ^retired, %VM.Status{phase: phase, cleanup: :ok}}
          when phase in [:stopped, :finished] -> :ok
    after 30_000 -> raise "controller loss did not certify VM teardown"
    end
    retire.(retired)
    failed_boot = define.(hypervisor: "/nonexistent/sower-hypervisor")
    :ok = Manager.start(failed_boot)
    {:error, _} = Manager.await_ready(failed_boot)
    retire.(failed_boot)
    :ok = Application.stop(:vm_manager)
    ensure.(File.ls!(root) == [])
    IO.puts("real network scenarios passed")
  '';
  networkRunner = pkgs.writeShellApplication {
    name = "image-network-scenario";
    runtimeInputs = [
      beamPackages.elixir
      pkgs.cloud-hypervisor
      pkgs.e2fsprogs
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      args=()
      while IFS= read -r directory; do
        args+=(-pa "$directory")
      done < <(find ${garden} -type d -name ebin)
      exec elixir "''${args[@]}" ${networkScenario}
    '';
  };
  restorationScenario = pkgs.writeText "image-restoration-scenario.exs" ''
    alias Garden.Image
    alias VMManager, as: VM
    alias CloudHypervisor.{API, Config}
    [phase] = System.argv()
    external = String.starts_with?(phase, "attach-")
    id = cond do
      String.starts_with?(phase, "agentless-") -> "agentless-restoration"
      external -> "external-restoration"
      String.starts_with?(phase, "graceful-") -> "graceful-restoration"
      true -> "host-restoration"
    end
    state = "/var/lib/image-restoration/" <> id
    File.mkdir_p!(state)
    Application.put_env(:vm_manager, :state_directory, state)
    :ok = Application.load(:garden)
    Code.ensure_loaded!(Garden.VM.Network)
    Code.ensure_loaded!(Garden.ActivatorClient)
    {:ok, _} = Application.ensure_all_started(:vm_manager)
    {:ok, image} = Image.load("${custom}")
    if String.starts_with?(phase, "agentless-") do
      if phase == "agentless-prepare" do
        File.mkdir_p!("/run/image-restoration")
        disk = "/var/lib/image-restoration/agentless.raw"
        File.write!(disk, "agentless-host-restoration")
        {_, 0} = System.cmd("truncate", ["--size", "16M", disk])
        config = %VM.Config{
          id: id,
          kernel: "${agentless}/kernel",
          initrd: "${agentless}/initrd",
          cmdline: "console=ttyS0 rd.systemd.unit=agentless.target",
          serial: %Config.Output{mode: :file, file: "serial.log"},
          disks: [%Config.Disk{path: disk, readonly: false, image_type: :raw}],
          runtime_directory: "/run/image-restoration",
          mkfs: "${pkgs.coreutils}/bin/false"
        }
        {:ok, ^id} = VM.define(config)
        :ok = VM.start(id)
      end
      {:ok, %VM.Status{running: true} = agentless} = VM.await_running(id)
      deadline = System.monotonic_time(:millisecond) + 30_000
      wait_serial = fn wait_serial ->
        case File.read(Path.join(agentless.directory, "serial.log")) do
          {:ok, log} ->
            unless String.contains?(log, "sower-agentless-userspace-ready") do
              if System.monotonic_time(:millisecond) >= deadline, do: raise("missing agentless userspace marker")
              Process.sleep(20)
              wait_serial.(wait_serial)
            end
          {:error, _} ->
            if System.monotonic_time(:millisecond) >= deadline, do: raise("missing agentless serial log")
            Process.sleep(20)
            wait_serial.(wait_serial)
        end
      end
      wait_serial.(wait_serial)
      {:error, :guest_agent_disabled} = VM.await_ready(id)
      if phase == "agentless-restore" do
        :ok = VM.stop(id)
        {:ok, %VM.Status{cleanup: :ok}} = VM.status(id)
        :ok = VM.remove(id)
        true = String.starts_with?(File.read!("/var/lib/image-restoration/agentless.raw"), "agentless-host-restoration")
        :ok = File.rm("/var/lib/image-restoration/agentless.raw")
      end
      IO.puts("agentless restoration phase passed: " <> phase)
      System.halt(0)
    end
    control = "/run/image-external/control.sock"
    guest = "/run/image-external/guest.sock"
    api = %API{socket: control}
    scratch = "/var/lib/image-restoration/external.ext4"
    if phase == "attach-prepare" do
      :ok = API.create(api, %Config{
        kernel: image.kernel, initramfs: image.initrd,
        cmdline: image.cmdline <> " sower.vm.id=" <> id,
        cpus: %Config.CPUs{boot_vcpus: 1, max_vcpus: 1}, memory: 536_870_912,
        disks: [
          %Config.Disk{path: image.root, readonly: true, image_type: :raw},
          %Config.Disk{path: scratch, readonly: false, image_type: :raw}
        ],
        vsock: %Config.Vsock{cid: 3, socket: guest},
        console: %Config.Output{mode: :off}, serial: %Config.Output{mode: :off},
        rng: %Config.RNG{src: "/dev/urandom"}
      })
      :ok = API.boot(api)
    end
    if phase in ["prepare", "graceful-prepare", "attach-prepare"] do
      overrides =
        if external do
          [mode: :attach, control_endpoint: control, vsock: %Config.Vsock{cid: 3, socket: guest}]
        else
          File.mkdir_p!("/run/image-restoration")
          [runtime_directory: "/run/image-restoration"]
        end
      config = Image.vm_config(image, id,
        Keyword.merge([scratch_bytes: 1024 * 1024 * 1024, boot_deadline_ms: 90_000], overrides))
      config =
        if external do
          %{config |
            serial: %Config.Output{mode: :off},
            disks: [
              %Config.Disk{path: image.root, readonly: true, image_type: :raw},
              %Config.Disk{path: scratch, readonly: false, image_type: :raw}
            ]}
        else
          config
        end
      {:ok, ^id} = VM.define(config)
      :ok = VM.start(id)
    end
    {:ok, _status} = VM.await_ready(id)
    if phase == "attach-prepare" do
      {:ok, handle} = VM.execute(id, %VM.Command{
        path: "/run/current-system/sw/bin/bash",
        args: ["-c", "printf survived > /var/external-reconnect"]
      })
      {:ok, %{code: 0}} = VM.await_command(handle)
      parent = self()
      {:ok, _interrupted} = VM.execute(id, %VM.Command{
        path: "${pkgs.python3}/bin/python3",
        args: ["-c", """
        import os, signal
        with open("/var/external-invocations", "ab", buffering=0) as record:
            record.write(b"invoked\\n")
            os.fsync(record.fileno())
        with open("/var/external-command-pid", "w") as record:
            record.write(str(os.getpid()))
            record.flush()
            os.fsync(record.fileno())
        print("interrupted-command-ready", flush=True)
        signal.pause()
        """]
      }, deadline_ms: 600_000,
        on_output: fn stream, bytes -> send(parent, {:interrupted_output, stream, bytes}) end)
      observe_ready = fn observe_ready, output ->
        receive do
          {:interrupted_output, :stdout, bytes} ->
            output = output <> bytes
            unless String.contains?(output, "interrupted-command-ready\n") do
              observe_ready.(observe_ready, output)
            end
        after 90_000 -> raise "interrupted guest command did not become ready"
        end
      end
      observe_ready.(observe_ready, "")
    else
      command =
        if external do
          %VM.Command{
            path: "${pkgs.python3}/bin/python3",
            args: ["-c", """
            import os
            assert open("/var/external-reconnect").read() == "survived"
            assert open("/var/external-invocations").read().splitlines() == ["invoked"]
            old_pid = int(open("/var/external-command-pid").read())
            assert not os.path.exists("/proc/" + str(old_pid))
            """]
          }
        else
          %VM.Command{path: "/run/current-system/sw/bin/bash", args: ["-c", "exit 0"]}
        end
      {:ok, handle} = VM.execute(id, command)
      {:ok, %{code: 0}} = VM.await_command(handle)
    end
    if phase in ["restore", "graceful-restore", "attach-restore"] do
      :ok = VM.stop(id)
      :ok = VM.remove(id)
      if external do
        {:ok, %API.Info{state: "Created", device_tree: nil}} = API.info(api)
        true = File.exists?(control)
      end
    end
    if phase == "graceful-prepare" do
      :ok = Application.stop(:vm_manager)
    end
    IO.puts("restoration phase passed: " <> phase)
    System.halt(0)
  '';
  restorationRunner = pkgs.writeShellApplication {
    name = "image-restoration-scenario";
    runtimeInputs = [
      beamPackages.elixir
      pkgs.cloud-hypervisor
      pkgs.e2fsprogs
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      args=()
      while IFS= read -r directory; do
        args+=(-pa "$directory")
      done < <(find ${garden} -type d -name ebin)
      exec elixir "''${args[@]}" ${restorationScenario} "$@"
    '';
  };
  protectedListener = pkgs.writeText "protected-listener.py" ''
    import selectors, socket
    selector = selectors.DefaultSelector()
    for kind, port in ((socket.SOCK_STREAM, 443), (socket.SOCK_STREAM, 18080), (socket.SOCK_DGRAM, 18080)):
        listener = socket.socket(socket.AF_INET, kind)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", port))
        if kind == socket.SOCK_STREAM:
            listener.listen()
        selector.register(listener, selectors.EVENT_READ, kind)
    open("/tmp/protected-deliveries", "w").close()
    while True:
        for key, _ in selector.select():
            if key.data == socket.SOCK_STREAM:
                connection, source = key.fileobj.accept()
                connection.close()
            else:
                _, source = key.fileobj.recvfrom(4096)
            with open("/tmp/protected-deliveries", "a") as log:
                log.write(repr(source) + "\n")
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
  nodes.machine =
    { config, lib, ... }:
    let
      cleanup =
        instance:
        "+${lib.getExe config.services.sower.activator.package} activator --network-policy ${config.services.sower.activator.network.policyFile} --network-cleanup --network-instance ${instance}";
    in
    {
      imports = [ ../nixos/module.nix ];
      services.sower.activator = {
        enable = true;
        package = flake.packages.${system}.activator;
        network = {
          enable = true;
          dnsResolver = "1.1.1.1";
          protectedDestinations = [ "93.184.216.34/32" ];
          gardenUnits = [
            "sower-garden.service"
            "sower-network-peer.service"
          ];
        };
      };
      environment.etc."sower-network-test-policy.json".source =
        config.services.sower.activator.network.policyFile;
      services.sower.garden = {
        enable = true;
        package = garden;
      };
      systemd.services.sower-garden = {
        wantedBy = lib.mkForce [ ];
        environment.SOWER_NETWORK_ROOT = "/var/lib/sower-garden/image-network-scenarios";
        serviceConfig = {
          Type = lib.mkForce "oneshot";
          WatchdogSec = lib.mkForce 0;
          Restart = lib.mkForce "no";
          TimeoutStartSec = 1800;
          ExecStart = lib.mkForce "${networkRunner}/bin/image-network-scenario";
          StandardOutput = "journal";
          StandardError = "journal";
        };
      };
      systemd.services.sower-network-peer = {
        after = [ "sower-activator.socket" ];
        inherit (config.systemd.services.sower-garden) path;
        environment = builtins.removeAttrs config.systemd.services.sower-garden.environment [ "PATH" ] // {
          SOWER_NETWORK_ROOT = "/var/lib/sower-garden/peer";
          SOWER_NETWORK_HOLD = "/var/lib/sower-garden/peer-marker.json";
        };
        serviceConfig = config.systemd.services.sower-garden.serviceConfig // {
          Type = "exec";
          ExecStartPre = [ (cleanup "sower-network-peer.service") ];
          ExecStopPost = [ (cleanup "sower-network-peer.service") ];
          StandardOutput = "journal";
          StandardError = "journal";
        };
      };
      virtualisation.vlans = [
        1
        2
      ];
      virtualisation.restrictNetwork = false;
      networking.interfaces.eth2.ipv4.addresses = [
        {
          address = "192.168.50.1";
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth2.ipv4.routes = [
        {
          address = "93.184.216.34";
          prefixLength = 32;
          via = "192.168.50.2";
        }
        {
          address = "169.254.169.254";
          prefixLength = 32;
          via = "192.168.50.2";
        }
      ];
      networking.firewall.allowedTCPPorts = [
        443
        18080
      ];
      networking.firewall.allowedUDPPorts = [ 18080 ];
      systemd.services.protected-listener = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${protectedListener}";
      };
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
      virtualisation.memorySize = 6144;
      virtualisation.diskSize = 16384;
      virtualisation.cores = 4;
      virtualisation.additionalPaths = [
        stock
        custom
        garden
      ];
      environment.systemPackages = [
        runner
        networkRunner
        restorationRunner
        pkgs.tcpdump
        pkgs.iproute2
        pkgs.nftables
      ];
    };
  nodes.protected = { ... }: {
    virtualisation.vlans = [
      1
      2
    ];
    networking.interfaces.eth2.ipv4.addresses = [
      {
        address = "192.168.50.2";
        prefixLength = 24;
      }
      {
        address = "93.184.216.34";
        prefixLength = 32;
      }
      {
        address = "169.254.169.254";
        prefixLength = 32;
      }
    ];
    networking.firewall.allowedTCPPorts = [
      443
      18080
    ];
    networking.firewall.allowedUDPPorts = [ 18080 ];
    systemd.services.protected-listener = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${protectedListener}";
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -c /dev/kvm")
    machine.succeed("image-scenario", timeout=1200)
    machine.succeed("test -z \"$(find /tmp/image-scenarios -mindepth 1 -print -quit)\"")
    machine.succeed("! pgrep --full '[c]loud-hypervisor'")
    machine.succeed("test -z \"$(find /tmp -maxdepth 1 -type d -name 'cloud-hypervisor-*' -print -quit)\"")
    machine.succeed("image-restoration-scenario graceful-prepare", timeout=120)
    machine.succeed("! pgrep --full '[c]loud-hypervisor'")
    machine.succeed("image-restoration-scenario graceful-restore", timeout=120)
    machine.succeed("image-restoration-scenario prepare", timeout=120)
    machine.succeed("image-restoration-scenario agentless-prepare", timeout=120)
    machine.reboot()
    machine.wait_for_shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("image-restoration-scenario restore", timeout=120)
    machine.succeed("image-restoration-scenario agentless-restore", timeout=120)
    machine.succeed("mkdir --parents /run/image-external /var/lib/image-restoration; truncate --size 1G /var/lib/image-restoration/external.ext4; ${pkgs.e2fsprogs}/bin/mkfs.ext4 -q -F -L sower-scratch /var/lib/image-restoration/external.ext4")
    machine.succeed("systemd-run --unit=image-external ${pkgs.cloud-hypervisor}/bin/cloud-hypervisor --api-socket /run/image-external/control.sock")
    machine.wait_until_succeeds("test -S /run/image-external/control.sock")
    external_pid = machine.succeed("systemctl show --property=MainPID --value image-external.service").strip()
    assert int(external_pid) > 0
    machine.succeed(f"test -d /proc/{external_pid}")
    machine.succeed("image-restoration-scenario attach-prepare", timeout=120)
    assert machine.succeed("systemctl show --property=MainPID --value image-external.service").strip() == external_pid
    machine.succeed("image-restoration-scenario attach-restore", timeout=120)
    assert machine.succeed("systemctl show --property=MainPID --value image-external.service").strip() == external_pid
    machine.succeed(f"test -d /proc/{external_pid}")
    machine.succeed("systemctl stop image-external.service")
    machine.succeed("! pgrep --full '[c]loud-hypervisor'")
    machine.wait_for_unit("protected-listener.service")
    protected.wait_for_unit("protected-listener.service")
    # Positive control establishes that the protected service is real and routed.
    machine.succeed("${pkgs.python3}/bin/python3 -c 'import socket; socket.create_connection((\"93.184.216.34\",443),3).close()'")
    protected.wait_until_succeeds("test -s /tmp/protected-deliveries")
    protected.succeed(": > /tmp/protected-deliveries")
    machine.succeed("${pkgs.python3}/bin/python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b\"positive-control\",(\"192.168.50.1\",18080))'")
    machine.wait_until_succeeds("test -s /tmp/protected-deliveries")
    machine.succeed(": > /tmp/protected-deliveries")
    machine.succeed("ip --oneline link show > /tmp/network-links-before")
    import json
    tables_before = {tuple((t["table"]["family"], t["table"]["name"])) for t in json.loads(machine.succeed("nft --json list tables"))["nftables"] if "table" in t}
    machine.succeed("""nft 'table ip sower_test_dnat { chain test_prerouting { type nat hook prerouting priority dstnat; policy accept; iifname "swnt*" ip daddr 93.184.216.34 tcp dport 443 dnat to 1.1.1.1:443; iifname "swnt*" ip daddr 8.8.4.4 tcp dport 18080 dnat to 1.1.1.1:443; }; }'""")
    machine.succeed("systemd-run --unit=sower-egress-observer ${pkgs.tcpdump}/bin/tcpdump --packet-buffered --interface eth0 -w /tmp/sower-egress.pcap 'src host 8.8.8.8 or (ip6 and udp port 18080) or (dst host 1.1.1.1 and tcp dst port 443)'")
    machine.wait_until_succeeds("test -s /tmp/sower-egress.pcap", timeout=10)
    result, output = machine.execute("systemctl start sower-garden.service", timeout=1800)
    print(machine.succeed("journalctl --unit=sower-garden.service --no-pager"))
    assert result == 0, output + machine.succeed("journalctl --unit=sower-garden.service --no-pager")
    machine.succeed("test -z \"$(find /var/lib/sower-garden/image-network-scenarios -mindepth 1 -print -quit)\"")

    from typing import Any

    def leases() -> list[dict[str, Any]]:
        paths = machine.succeed("find /run/sower-network -name '*.json' -print").splitlines()
        return [json.loads(machine.succeed(f"cat {path}")) for path in paths]

    machine.succeed("mkdir --parents /run/systemd/system/sower-garden.service.d; printf '%s\\n' '[Service]' 'Environment=SOWER_NETWORK_HOLD=/var/lib/sower-garden/hold.json' > /run/systemd/system/sower-garden.service.d/10-hold.conf; systemctl daemon-reload")
    machine.succeed("systemctl start --no-block sower-garden.service sower-network-peer.service")
    machine.wait_until_succeeds("test -s /var/lib/sower-garden/hold.json -a -s /var/lib/sower-garden/peer-marker.json", timeout=90)
    concurrent = leases()
    assert len(concurrent) == 2, concurrent
    assert concurrent[0]["address"] != concurrent[1]["address"], concurrent
    peer = next(lease for lease in concurrent if lease["instance"] == "sower-network-peer.service")
    peer_table = "sower_network_" + peer["lease"]
    peer_policy = json.loads(machine.succeed(f"nft --json list table inet {peer_table}"))
    machine.wait_until_succeeds("! pgrep --full '[s]ower activator'", timeout=15)
    machine.succeed("systemctl stop sower-garden.service")
    assert leases() == [peer], leases()
    machine.succeed(f"ip link show dev {peer['tap']}")
    assert json.loads(machine.succeed(f"nft --json list table inet {peer_table}")) == peer_policy
    retained = machine.fail("${
      flake.packages.${system}.activator
    }/bin/sower activator --network-policy \"$(readlink --canonicalize /etc/sower-network-test-policy.json)\" --network-cleanup --network-instance sower-network-peer.service 2>&1")
    print(retained)
    assert leases()[0]["phase"] == "quarantined", leases()
    machine.succeed("systemctl stop sower-network-peer.service")
    assert leases() == [], leases()
    machine.succeed("rm --recursive --force /var/lib/sower-garden/image-network-scenarios/sower-vm-* /var/lib/sower-garden/peer/sower-vm-*")

    machine.succeed("rm --force /var/lib/sower-garden/hold.json; printf '%s\\n' '[Service]' 'Environment=SOWER_NETWORK_EXPECT_FAILURE=1' > /run/systemd/system/sower-garden.service.d/30-interrupt.conf; systemctl daemon-reload")
    machine.succeed("udevadm control --stop-exec-queue")
    try:
        machine.succeed("systemctl start --no-block sower-garden.service")
        machine.wait_until_succeeds("test -d /sys/class/net/swnt0000 && test -n \"$(cat /sys/class/net/swnt0000/ifalias)\"", timeout=15)
        [interrupted] = leases()
        assert interrupted["phase"] == "allocated", interrupted
        link = json.loads(machine.succeed("ip --json link show dev swnt0000"))[0]
        assert "UP" not in link["flags"], link
        [worker] = [line.split()[0] for line in machine.succeed("systemctl list-units --type=service --state=running --plain --no-legend 'sower-activator@*.service'").splitlines()]
        machine.succeed(f"systemctl kill --kill-whom=all --signal=KILL {worker}")
        machine.wait_until_succeeds("test \"$(systemctl show --property=ActiveState --value sower-garden.service)\" = inactive", timeout=30)
        print(machine.succeed("journalctl --unit=sower-garden.service --no-pager --lines=30"))
        machine.succeed("! pgrep --full '[c]loud-hypervisor'")
        assert leases() == [], leases()
    finally:
        machine.succeed("udevadm control --start-exec-queue; rm --force /run/systemd/system/sower-garden.service.d/30-interrupt.conf; systemctl daemon-reload")
    machine.succeed("rm --recursive --force /var/lib/sower-garden/image-network-scenarios/sower-vm-*")

    for failure in ("garden-owner", "service-stop", "startup-reconcile"):
        machine.succeed("rm --force /var/lib/sower-garden/hold.json; systemctl reset-failed sower-garden.service; systemctl start --no-block sower-garden.service")
        machine.wait_until_succeeds("test -s /var/lib/sower-garden/hold.json", timeout=90)
        owner = json.loads(machine.succeed("cat /var/lib/sower-garden/hold.json"))
        machine.succeed(f"test -d /proc/{owner['vmm']}")
        [old] = leases()
        if failure == "startup-reconcile":
            machine.succeed("printf '%s\\n' '[Service]' 'ExecStopPost=' > /run/systemd/system/sower-garden.service.d/20-no-post.conf; systemctl daemon-reload")
        if failure == "service-stop":
            machine.succeed("systemctl stop sower-garden.service")
        else:
            machine.succeed("systemctl kill --kill-whom=main --signal=KILL sower-garden.service")
            machine.wait_until_succeeds("test \"$(systemctl show --property=ActiveState --value sower-garden.service)\" = failed", timeout=60)
        machine.wait_until_succeeds("! pgrep --full '[c]loud-hypervisor'", timeout=60)
        if failure == "startup-reconcile":
            assert leases() == [old], leases()
            machine.succeed("rm --force /run/systemd/system/sower-garden.service.d/20-no-post.conf /var/lib/sower-garden/hold.json; systemctl daemon-reload; systemctl reset-failed sower-garden.service; systemctl start --no-block sower-garden.service")
            machine.wait_until_succeeds("test -s /var/lib/sower-garden/hold.json", timeout=90)
            [fresh] = leases()
            assert fresh["lease"] != old["lease"], (old, fresh)
            machine.fail(f"nft list table inet sower_network_{old['lease']}")
            machine.succeed("systemctl stop sower-garden.service")
        assert leases() == [], leases()
        machine.succeed("rm --recursive --force /var/lib/sower-garden/image-network-scenarios/sower-vm-*")
    machine.succeed("systemctl stop sower-egress-observer")
    captured = machine.succeed("${pkgs.tcpdump}/bin/tcpdump -n -r /tmp/sower-egress.pcap 2>/dev/null")
    assert captured == "", captured
    machine.succeed("test ! -s /tmp/protected-deliveries")
    protected.succeed("test ! -s /tmp/protected-deliveries")
    machine.succeed("nft delete table ip sower_test_dnat")
    machine.succeed("ip --oneline link show > /tmp/network-links-after; diff --unified /tmp/network-links-before /tmp/network-links-after")
    tables_after = {tuple((t["table"]["family"], t["table"]["name"])) for t in json.loads(machine.succeed("nft --json list tables"))["nftables"] if "table" in t}
    assert tables_after == tables_before, (tables_before, tables_after)
    assert leases() == [], leases()
    machine.succeed("test -z \"$(find /var/lib/sower-garden/image-network-scenarios -mindepth 1 -print -quit)\"")
    machine.succeed("! pgrep --full '[c]loud-hypervisor'")
  '';
}
