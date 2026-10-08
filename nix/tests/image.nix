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
    {:ok, stock} = Image.load("${stock}")
    {:ok, custom} = Image.load("${custom}")
    root = "/tmp/image-scenarios"
    File.mkdir!(root)
    opts = [resource_directory: root, deadline_ms: 90_000, scratch_bytes: 1024 * 1024 * 1024]
    command = fn mode, args ->
      %Image.Command{path: "${pkgs.python3}/bin/python3", args: ["/etc/sower/probe.py", mode | args],
        env: %{"ONLY" => "provided", "PYTHONCOERCECLOCALE" => "0"},
        stdin: %{"message" => "stdin", "number" => 7}}
    end
    ensure = fn condition -> if not condition, do: raise("image lifecycle assertion failed") end
    clean = fn -> ensure.(File.ls!(root) == []) end
    parent = self()
    output = fn stream, bytes -> send(parent, {stream, bytes}) end
    {:ok, missing_vmm} = Image.start_link(opts ++ [image: stock,
      command: %Image.Command{path: "/run/current-system/sw/bin/true"},
      hypervisor: "/nonexistent/sower-hypervisor"])
    {:error, {:vmm_failed, {:startup, startup_message}}} = Image.await(missing_vmm)
    ensure.(is_binary(startup_message))
    missing_status = Image.status(missing_vmm)
    ensure.(missing_status.cleanup == :ok and missing_status.os_pid == nil)
    ensure.(is_pid(missing_status.vmm) and not Process.alive?(missing_status.vmm))
    GenServer.stop(missing_vmm)
    clean.()
    {:ok, failed_formatter} = Image.start_link(opts ++ [image: stock,
      command: %Image.Command{path: "/run/current-system/sw/bin/true"},
      mkfs: "${pkgs.coreutils}/bin/false"])
    {:error, {:mkfs, {:shutdown, {:exit_status, 1}}}} = Image.await(failed_formatter)
    formatter_status = Image.status(failed_formatter)
    ensure.(formatter_status.cleanup == :ok and formatter_status.vmm == nil)
    GenServer.stop(failed_formatter)
    clean.()
    {:ok, result} = Image.run(stock, %Image.Command{path: "/run/current-system/sw/bin/bash",
      args: ["-c", "printf stock-command"]}, Keyword.put(opts, :on_output, output))
    ensure.(result.code == 0)
    receive do {:stdout, "stock-command"} -> :ok after 1000 -> raise "missing stock output" end
    clean.()
    {:ok, cli_result} = Garden.Image.CLI.main(["${stock}", "--path",
      "/run/current-system/sw/bin/bash", "--argv", "[\"-c\",\"printf cli-command\"]",
      "--scratch-mib", "1024", "--deadline-ms", "90000"])
    ensure.(cli_result.code == 0)
    {:ok, result} = Image.run(custom, command.("exact", ["space argument", "", "literal;$x"]),
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
    {:ok, a} = Image.start_link(opts ++ [image: custom, command: command.("write", ["a", "2"])])
    {:ok, b} = Image.start_link(opts ++ [image: custom, command: command.("write", ["b", "0"])])
    {:ok, ra} = Image.await(a)
    {:ok, rb} = Image.await(b)
    ensure.(ra.code == 0 and rb.code == 0)
    GenServer.stop(a)
    GenServer.stop(b)
    clean.()
    {:ok, fresh} = Image.run(custom, command.("write", ["fresh", "0"]), opts)
    ensure.(fresh.code == 0)
    clean.()
    wait = fn wait, execution ->
      status = Image.status(execution)
      if status.phase == :running, do: status, else: (Process.sleep(20); wait.(wait, execution))
    end
    blocked = fn _, _ -> receive do :never -> :ok end end
    drain = fn _, _ -> :ok end
    {:ok, timed} = Image.start_link(Keyword.merge(opts,
      image: custom, command: command.("block", []), on_output: blocked, deadline_ms: 30_000))
    {:error, :timeout} = Image.await(timed)
    GenServer.stop(timed)
    clean.()
    {:ok, cancelled} = Image.start_link(opts ++ [image: custom, command: command.("block", []), on_output: blocked])
    wait.(wait, cancelled)
    :ok = Image.cancel(cancelled)
    {:error, :cancelled} = Image.await(cancelled)
    GenServer.stop(cancelled)
    clean.()
    owner = spawn(fn -> receive do :never -> :ok end end)
    {:ok, orphan} = Image.start_link(opts ++ [image: custom, command: command.("block", []),
      owner: owner, on_output: drain])
    wait.(wait, orphan)
    Process.exit(owner, :kill)
    {:error, :owner_down} = Image.await(orphan)
    GenServer.stop(orphan)
    clean.()
    {:ok, dead} = Image.start_link(opts ++ [image: custom, command: command.("block", []),
      on_output: drain])
    status = wait.(wait, dead)
    {_, 0} = System.cmd("kill", ["--signal", "KILL", Integer.to_string(status.os_pid)])
    {:error, _} = Image.await(dead)
    ensure.(Image.status(dead).cleanup == :ok)
    GenServer.stop(dead)
    clean.()
    {:ok, severed} = Image.start_link(opts ++ [image: custom, command: command.("block", []),
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
    {:ok, retained} = Image.start_link(opts ++ [image: custom, command: command.("block", [])])
    status = wait.(wait, retained)
    unexpected = Path.join(status.directory, "unowned")
    File.write!(unexpected, "retain me")
    :ok = Image.cancel(retained)
    {:error, {:cleanup_unconfirmed, {:error, :cancelled},
      {:error, {:unexpected_files, ["unowned"]}}, directory}} = Image.await(retained)
    ensure.(directory == status.directory and File.read!(unexpected) == "retain me")
    ensure.(File.exists?(Path.join(directory, "scratch.ext4")))
    GenServer.stop(retained)
    Enum.each(["unowned", "scratch.ext4", "serial.log"], fn name ->
      :ok = File.rm(Path.join(directory, name))
    end)
    :ok = File.rmdir(directory)
    clean.()
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
    machine.succeed("image-scenario", timeout=600)
    machine.succeed("test -z \"$(find /tmp/image-scenarios -mindepth 1 -print -quit)\"")
    machine.succeed("! pgrep --full '[c]loud-hypervisor'")
    machine.succeed("test -z \"$(find /tmp -maxdepth 1 -type d -name 'cloud-hypervisor-*' -print -quit)\"")
  '';
}
