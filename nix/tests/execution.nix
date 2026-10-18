{ pkgs, flake, ... }:
let
  system = pkgs.stdenv.hostPlatform.system;
  garden = flake.packages.${system}.garden;
  server = flake.packages.${system}.server;
  sower = flake.packages.${system}.sower;
  activator = flake.packages.${system}.activator;
  secondConfig = pkgs.writeText "second-builder.json" (
    builtins.toJSON {
      name = "second-builder";
      endpoint = "http://localhost:4000";
      access_token_file = "/run/sower/test_token";
      state_directory = "/var/lib/sower-garden2";
      admin_socket = "/run/sower-garden2/admin.sock";
      activator_socket = "/run/sower-activator/activator.sock";
      builder = true;
      builder_network = true;
      vm_result_limit = 0;
      vm_capacity = {
        vms = 1;
        cpus = 2;
        memory = 4294967296;
        scratch_bytes = 4294967296;
      };
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "sower-execution";
  nodes.machine = { config, ... }: {
    imports = [ ../nixos/module.nix ];
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
    virtualisation.restrictNetwork = false;
    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
    virtualisation.diskSize = 20480;
    environment.systemPackages = [
      sower
      pkgs.python3
      pkgs.curl
      pkgs.procps
      pkgs.iproute2
      pkgs.nftables
    ];
    services.postgresql = {
      enable = true;
      initialScript = pkgs.writeText "execution-pg-init" ''
        CREATE USER sower;
        CREATE DATABASE sower OWNER sower;
      '';
    };
    services.sower = {
      server = {
        enable = true;
        package = server;
        initSecrets = true;
        e2eTest = true;
        settings = {
          listen_address = "127.0.0.1";
          public_url = "http://localhost:4000";
          database = {
            socket = "/run/postgresql/.s.PGSQL.5432";
            username = "sower";
            database = "sower";
            encryption_key_file = pkgs.writeText "execution-encryption-key" "UIFQeYN5EBgkXgK502I8mosh3vbEj3AE1rRwWJDysBk=";
          };
          clients.${system}.path = toString sower;
          execution_queue_wait_ms = 600000;
        };
      };
      activator = {
        package = activator;
        network = {
          enable = true;
          gardenUnits = [
            "sower-garden.service"
            "sower-garden2.service"
          ];
          dnsResolver = "1.1.1.1";
        };
      };
      garden = {
        enable = true;
        package = garden;
        settings = {
          name = "first-builder";
          endpoint = "http://localhost:4000";
          access_token_file = "/run/sower/test_token";
          builder = true;
          builder_network = true;
          vm_result_limit = 0;
          vm_capacity = {
            vms = 1;
            cpus = 2;
            memory = 4294967296;
            scratch_bytes = 4294967296;
          };
        };
      };
    };
    systemd.services.sower-garden2 = {
      wantedBy = [ "multi-user.target" ];
      path = config.systemd.services.sower-garden.path;
      after = [
        "sower.service"
        "sower-activator.socket"
      ];
      environment = {
        SOWER_CONFIG_FILE = toString secondConfig;
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "disposable-execution-test";
      };
      serviceConfig = {
        User = "sower-garden";
        Group = "sower-garden";
        SupplementaryGroups = [
          "kvm"
          "sower-activator"
        ];
        StateDirectory = "sower-garden2";
        RuntimeDirectory = "sower-garden2";
        WorkingDirectory = "/var/lib/sower-garden2";
        ExecStart = "${garden}/bin/sower-garden start";
        ExecStartPre = "+${activator}/bin/sower activator --network-policy ${config.services.sower.activator.network.policyFile} --network-cleanup --network-instance sower-garden2.service";
        ExecStopPost = "+${activator}/bin/sower activator --network-policy ${config.services.sower.activator.network.policyFile} --network-cleanup --network-instance sower-garden2.service";
      };
    };
  };
  testScript = ''
    import base64, json, shlex, time
    start_all()
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("sower.service")
    machine.wait_for_open_port(4000)
    machine.wait_for_unit("sower-garden.service")
    machine.wait_for_unit("sower-garden2.service")

    def rpc(expression):
        return machine.succeed("sower-server rpc " + shlex.quote(expression))

    rpc('user = Sower.Repo.one!(Sower.Accounts.User, skip_org_id: true); '
        'token = Sower.Repo.Seeds.Org.access_token(user, "execution acceptance", '
        '%{"permissions" => ["execution:create", "execution:read", "execution:cancel"]}); '
        'File.write!("/var/lib/sower/execution_token", token.token)')
    cli = "SOWER_ENDPOINT=http://localhost:4000 SOWER_ACCESS_TOKEN_FILE=/var/lib/sower/execution_token sower execution "

    def api(path, method="GET", body=None):
        command = "curl --fail --silent --show-error --request " + method
        command += ' --header "Authorization: Bearer $(cat /var/lib/sower/execution_token)"'
        if body is not None:
            command += " --header 'Content-Type: application/json' --data " + shlex.quote(json.dumps(body))
        command += " " + shlex.quote("http://localhost:4000/api/v1" + path)
        return json.loads(machine.succeed(command))

    def request(script=None, **overrides):
        value = dict(system="x86_64-linux", path="/run/current-system/sw/bin/bash",
                     args=["-c", script or "printf execution-success"], env={"PATH": "/run/current-system/sw/bin"},
                     stdin={"literal": "JSON stdin"}, cpus=1, memory=4294967296,
                     scratch_bytes=4294967296, network="full", timeout_ms=120000)
        value.update(overrides)
        return value

    def submit(value):
        machine.succeed("printf %s " + shlex.quote(json.dumps(value)) + " > /tmp/execution-request.json")
        sid = machine.succeed(cli + "submit --detach --request /tmp/execution-request.json").strip()
        assert sid.startswith("exec_"), sid
        return sid

    def state(sid):
        return api("/executions/" + sid)

    def wait_state(sid, expected, timeout=120, cleanup=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = state(sid)
            if value["state"] in expected and (cleanup is None or (value["result"] or {}).get("cleanup") == cleanup):
                return value
            time.sleep(0.2)
        raise AssertionError(state(sid))

    def logs(sid):
        cursor, streams = 0, {"stdout": b"", "stderr": b""}
        while True:
            history = api(f"/executions/{sid}/logs?after={cursor}")
            for event in history["events"]:
                if event["kind"] == "log":
                    streams[event["stream"]] += base64.b64decode(event["bytes"])
            if history["cursor"] == cursor:
                return streams
            cursor = history["cursor"]

    def clean():
        machine.wait_until_succeeds("! pgrep --full '[c]loud-hypervisor'", timeout=30)
        machine.wait_until_succeeds("test -z \"$(find /run/sower-network -name '*.json' -print -quit)\"", timeout=30)
        machine.succeed("! ip --oneline link show | grep 'swnt'")
        machine.succeed("! nft list tables | grep 'sower_network_'")

    machine.wait_until_succeeds("sower-server rpc 'IO.puts(Sower.Repo.aggregate(Sower.Executions.Builder, :count, skip_org_id: true))' | grep '^2$'", timeout=60)

    with subtest("real stock-image Nix cowsay through CLI, API and two connected builders"):
        sid = submit(request(path="/run/current-system/sw/bin/nix",
            args=["run", "github:NixOS/nixpkgs/${
              builtins.readFile (pkgs.path + "/.git-revision")
            }#cowsay", "--", "hello from dispatched sower"],
            timeout_ms=600000))
        final = wait_state(sid, ["succeeded", "failed"], timeout=900)
        assert final["state"] == "succeeded", (final, logs(sid))
        assert final["garden_sid"], final
        assert final["result"]["code"] == 0 and final["result"]["cleanup"] == "complete", final
        assert b"< hello from dispatched sower >" in logs(sid)["stdout"]
        assert "hello from dispatched sower" in machine.succeed(cli + "logs --follow " + sid)
        clean()

    with subtest("binary stdout/stderr, literal argv/env/JSON stdin and guest exit status"):
        sid = submit(request("printf 'out\\000\\377'; printf 'err\\000\\376' >&2; exit 23"))
        final = wait_state(sid, ["failed"])
        assert final["result"]["code"] == 23 and final["result"]["signal"] is None, final
        assert logs(sid) == {"stdout": b"out\x00\xff", "stderr": b"err\x00\xfe"}
        code, _ = machine.execute(cli + "logs --follow " + sid + " > /tmp/execution-cli-out 2> /tmp/execution-cli-err")
        assert code == 23, code
        assert base64.b64decode(machine.succeed("base64 --wrap=0 /tmp/execution-cli-out")) == b"out\x00\xff"
        assert base64.b64decode(machine.succeed("base64 --wrap=0 /tmp/execution-cli-err")) == b"err\x00\xfe"
        sid = submit(request('printf "%s\\n" "$1" "$BOUNDARY"; cat',
            args=["-c", 'printf "%s\\n" "$1" "$BOUNDARY"; cat', "literal", "a b;$HOME"],
            env={"PATH": "/run/current-system/sw/bin", "BOUNDARY": "x y;$USER"}, stdin=[1, {"a": "b"}]))
        wait_state(sid, ["succeeded"])
        output = logs(sid)["stdout"].split(b"\n", 2)
        assert output[:2] == [b"a b;$HOME", b"x y;$USER"], output
        assert json.loads(output[2]) == [1, {"a": "b"}]
        sid = submit(request("kill -TERM $$"))
        final = wait_state(sid, ["failed"])
        assert final["result"]["signal"] == 15 and final["result"]["code"] is None, final
        code, _ = machine.execute(cli + "logs --follow " + sid)
        assert code == 143, code
        clean()

    with subtest("guest spawn failure remains an error rather than a fabricated exit code"):
        sid = submit(request(path="/missing-sower-guest-executable", args=[]))
        final = wait_state(sid, ["failed"])
        assert final["result"]["error"] == "guest", final
        assert final["result"]["code"] is None and final["result"]["signal"] is None, final
        assert final["result"]["cleanup"] == "complete", final
        clean()

    with subtest("durable disconnected queue, server restart and queued cancellation"):
        machine.succeed("systemctl stop sower-garden.service sower-garden2.service")
        queued = submit(request())
        cancelled = submit(request())
        assert state(queued)["state"] == "queued"
        machine.succeed(cli + "cancel " + cancelled)
        assert state(cancelled)["state"] == "cancelled" and state(cancelled).get("garden_sid") is None
        machine.succeed("systemctl restart sower.service")
        machine.wait_for_open_port(4000)
        assert state(queued)["state"] == "queued"
        machine.succeed("systemctl start sower-garden.service")
        wait_state(queued, ["succeeded"])
        assert state(cancelled)["state"] == "cancelled"
        clean()

    with subtest("busy queue, explicit cancellation, timeout and certified capacity recovery"):
        first = submit(request("printf ready; sleep 90"))
        wait_state(first, ["running"])
        second = submit(request())
        assert state(second)["state"] == "queued", state(second)
        machine.succeed(cli + "cancel " + second)
        machine.succeed(cli + "cancel " + first)
        final = wait_state(first, ["cancelled"])
        assert final["result"]["cleanup"] == "complete", final
        assert state(second).get("garden_sid") is None
        clean()
        timed = submit(request("printf ready; sleep 90", timeout_ms=20000))
        final = wait_state(timed, ["failed"])
        assert final["result"]["error"] == "execution_timeout", final
        assert final["result"]["cleanup"] == "complete", final
        clean()
        recovered = submit(request())
        wait_state(recovered, ["succeeded"])
        clean()
        followed = machine.succeed(cli + "submit --request /tmp/execution-request.json", timeout=120)
        assert "execution-success" in followed
        listed = json.loads(machine.succeed(cli + "list"))
        latest = listed[0]
        inspected = json.loads(machine.succeed(cli + "status " + latest["sid"]))
        assert inspected["state"] == "succeeded" and inspected["result"]["cleanup"] == "complete", inspected
        clean()

    with subtest("concurrent queued claims reserve two builders once without oversubscription"):
        machine.succeed("systemctl start sower-garden2.service")
        machine.wait_until_succeeds("sower-server rpc 'IO.puts(Sower.Repo.aggregate(Sower.Executions.Builder, :count, skip_org_id: true))' | grep '^2$'", timeout=60)
        rpc(':sys.suspend(Sower.Executions.Dispatcher)')
        try:
            sid = submit(request("printf unique-invocation; sleep 90", memory=536870912, scratch_bytes=1073741824))
            peer = submit(request("printf peer-invocation; sleep 90", memory=536870912, scratch_bytes=1073741824))
            queued = submit(request("printf must-not-run", memory=536870912, scratch_bytes=1073741824))
            assert all(state(value)["state"] == "queued" for value in [sid, peer, queued])
            rpc('1..16 |> Task.async_stream(fn _ -> Sower.Executions.dispatch() end, max_concurrency: 16, timeout: 30000) |> Enum.each(fn {:ok, :ok} -> :ok end)')
        finally:
            rpc(':sys.resume(Sower.Executions.Dispatcher)')
        first = wait_state(sid, ["running"])
        second = wait_state(peer, ["running"])
        assert first["garden_sid"] != second["garden_sid"]
        assert state(queued)["state"] == "queued" and state(queued).get("garden_sid") is None
        machine.succeed(cli + "cancel " + queued)
        for value in [sid, peer]:
            observed = rpc('e = Sower.Repo.get_by!(Sower.Executions.Execution, [sid: "' + value + '"], skip_org_id: true); IO.puts(e.attempt)')
            assert "1" in observed.splitlines(), observed
        expression = ('e = Sower.Repo.get_by!(Sower.Executions.Execution, [sid: "' + sid + '"], skip_org_id: true); '
            'p = %{sid: e.sid, run_sid: e.run_sid, session: e.session, attempt: e.attempt, request: e.request}; ')
        rpc(expression + 'Enum.each(1..5, fn _ -> Phoenix.PubSub.broadcast(Sower.PubSub, "execution:session:" <> e.session, {:execution_dispatch, p}) end)')
        rpc(expression + 'p = %{p | request: Map.put(p.request, "args", ["-c", "printf conflicting-invocation"])}; '
            'Phoenix.PubSub.broadcast(Sower.PubSub, "execution:session:" <> e.session, {:execution_dispatch, p})')
        time.sleep(1)
        vmms = machine.succeed("pgrep --list-full --full '(^cloud-hypervisor|^[^ ]*/cloud-hypervisor)( |$)'")
        assert len(vmms.strip().splitlines()) == 2, vmms
        assert logs(sid)["stdout"] == b"unique-invocation"
        assert logs(peer)["stdout"] == b"peer-invocation"
        assert state(sid)["state"] == "running"
        observer_code, _ = machine.execute("timeout --signal=INT 2s env " + cli + "logs --follow " + sid)
        assert observer_code == 124 and state(sid)["state"] == "running"
        for _ in range(5):
            machine.succeed(cli + "cancel " + sid)
        wait_state(sid, ["cancelled"])
        machine.succeed(cli + "cancel " + peer)
        wait_state(peer, ["cancelled"])
        clean()
        machine.succeed("systemctl stop sower-garden2.service")

    with subtest("server restart around an accepted command fails closed without replay"):
        sid = submit(request("printf server-owned-once; sleep 90"))
        wait_state(sid, ["running"])
        machine.succeed("systemctl restart sower.service")
        machine.wait_for_open_port(4000)
        final = wait_state(sid, ["failed"], cleanup="complete")
        assert final["result"]["error"] == "builder_disconnected", final
        assert logs(sid)["stdout"] == b"server-owned-once"
        clean()

    with subtest("finite queue expiry is distinct from VM execution timeout"):
        machine.succeed("systemctl stop sower-garden.service")
        rpc('Application.put_env(:sower, :execution_queue_wait_ms, 1000)')
        expired = submit(request(timeout_ms=120000))
        final = wait_state(expired, ["failed"])
        assert final["result"]["error"] == "queue_timeout" and final.get("garden_sid") is None, final
        rpc('Application.put_env(:sower, :execution_queue_wait_ms, 600000)')
        machine.succeed("systemctl start sower-garden.service")

    with subtest("cleanup failure remains retained across restart without a teardown certificate"):
        sid = submit(request("printf cleanup-probe; sleep 8; exit 29"))
        wait_state(sid, ["running"])
        machine.succeed("systemctl stop sower-activator.socket")
        retained = wait_state(sid, ["failed"])
        assert retained["result"]["cleanup"] == "incomplete", retained
        assert retained["result"]["code"] == 29, retained
        assert retained["result"]["cleanup_error"], retained
        machine.wait_until_succeeds("! pgrep --full '[c]loud-hypervisor'", timeout=30)
        machine.succeed("test -n \"$(find /run/sower-network -name '*.json' -print -quit)\"")
        waiting = submit(request())
        assert state(waiting)["state"] == "queued"
        machine.succeed("systemctl start sower-activator.socket; systemctl restart sower-garden.service")
        machine.wait_for_unit("sower-garden.service")
        time.sleep(3)
        assert state(waiting)["state"] == "queued"
        assert state(sid)["result"] == retained["result"]
        machine.succeed("systemctl start sower-garden2.service")
        wait_state(waiting, ["succeeded"])
        assert state(waiting)["garden_sid"] != retained["garden_sid"]
        assert state(sid)["state"] == "failed" and state(sid)["result"] == retained["result"]
        clean()

    with subtest("builder loss retains uncertain custody without replay or unsafe capacity recovery"):
        sid = submit(request("printf once; sleep 90"))
        wait_state(sid, ["running"])
        machine.succeed("systemctl kill --kill-whom=main --signal=KILL sower-garden2.service")
        final = wait_state(sid, ["failed"])
        assert final["result"]["error"] == "builder_disconnected", final
        clean()
        machine.succeed("systemctl reset-failed sower-garden2.service; systemctl start sower-garden2.service")
        machine.wait_for_unit("sower-garden2.service")
        time.sleep(3)
        assert state(sid)["state"] == "failed"
        assert state(sid)["result"]["cleanup"] == "unknown"
        assert logs(sid)["stdout"] == b"once"
        waiting = submit(request())
        assert state(waiting)["state"] == "queued"
        api("/executions/" + waiting + "/cancel", "POST")
        wait_state(waiting, ["cancelled"])
        clean()

    with subtest("deployment-only token cannot submit arbitrary commands"):
        code, _ = machine.execute("curl --silent --output /tmp/forbidden --write-out '%{http_code}' --header \"Authorization: Bearer $(cat /run/sower/test_token)\" --header 'Content-Type: application/json' --data '{}' http://localhost:4000/api/v1/executions")
        machine.succeed("printf %s " + shlex.quote(json.dumps(request())) + " > /tmp/execution-request.json")
        status = machine.succeed("curl --silent --output /tmp/forbidden --write-out '%{http_code}' --header \"Authorization: Bearer $(cat /run/sower/test_token)\" --header 'Content-Type: application/json' --data @/tmp/execution-request.json http://localhost:4000/api/v1/executions")
        assert status == "403", status
    machine.succeed("systemctl stop sower-garden.service sower-garden2.service")
    clean()
  '';
}
