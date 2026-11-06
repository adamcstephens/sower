defmodule VMManager.StoreRuntimeTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Manager, Status, Store}

  @moduletag :tmp_dir

  test "a fresh BEAM restores dependency diagnostics and boots with persisted failures",
       %{tmp_dir: dir} do
    diagnostic = %CloudHypervisor.API.Error{
      kind: :transport,
      reason: %Req.TransportError{reason: :timeout}
    }

    crashed =
      try do
        raise Req.TransportError, reason: :timeout
      rescue
        error in Req.TransportError -> {error, __STACKTRACE__}
      end

    config = %Config{id: "failed-api", kernel: "/kernel"}

    definition = %Manager.Definition{
      config: config,
      desired: :stopped,
      failure: {:vm_failed, {:error, {:guard_down, crashed}}},
      observed: %Status{
        config: config,
        phase: :failed,
        result: {:error, diagnostic},
        cleanup: :ok
      }
    }

    assert :ok = Store.save(dir, %{config.id => definition})
    certificate = Path.join(dir, "diagnostic.etf")

    certificate_diagnostic = %CloudHypervisor.API.Error{
      kind: :transport,
      reason: %Mint.HTTPError{reason: {:unexpected_trailing_responses, []}, module: Mint.HTTP1}
    }

    assert :ok =
             Store.write_certificate(
               certificate,
               "failed-attempt",
               {:error, certificate_diagnostic},
               :ok
             )

    assert :ok =
             Store.write_certificate(
               Path.join(dir, "crashed.etf"),
               "crashed-attempt",
               {:error, {:guard_down, crashed}},
               {:error, {:external_shutdown, crashed}}
             )

    reader = """
    directory = System.fetch_env!("VM_MANAGER_COLD_STATE")
    IO.puts("cold-stage: definitions")
    {:ok, definitions} = VMManager.Store.load(directory)
    definition = definitions["failed-api"]
    "stopped" = Atom.to_string(definition.desired)
    "failed" = Atom.to_string(definition.observed.phase)
    "ok" = Atom.to_string(definition.observed.cleanup)
    {:error, diagnostic} = definition.observed.result
    text = inspect(diagnostic, limit: :infinity)
    true = String.contains?(text, "Req.TransportError")
    true = String.contains?(text, "timeout")
    true = String.contains?(inspect(definition.failure, limit: :infinity), "StoreRuntimeTest")
    IO.puts("cold-stage: crash-certificate")
    {:ok, crashed} = VMManager.Store.certificate(Path.join(directory, "crashed.etf"))
    {:error, _} = crashed.result
    {:error, _} = crashed.cleanup
    true = String.contains?(inspect(crashed.result, limit: :infinity), "StoreRuntimeTest")
    true = String.contains?(inspect(crashed.cleanup, limit: :infinity), "StoreRuntimeTest")
    IO.puts("cold-stage: dependency-certificate")
    {:ok, certificate} = VMManager.Store.certificate(Path.join(directory, "diagnostic.etf"))
    "failed-attempt" = certificate.attempt
    "ok" = Atom.to_string(certificate.cleanup)
    {:error, certificate_diagnostic} = certificate.result
    text = inspect(certificate_diagnostic, limit: :infinity)
    true = String.contains?(text, "Mint.HTTPError")
    true = String.contains?(text, "unexpected_trailing_responses")
    IO.puts("cold-stage: application")
    Application.put_env(:vm_manager, :state_directory, directory)
    {:ok, _} = Application.ensure_all_started(:vm_manager)
    {:ok, [status]} = VMManager.list()
    "failed-api" = status.id
    true = status.result == definition.observed.result
    IO.puts("cold-dependency-diagnostics-restored")
    """

    paths =
      Enum.flat_map(:code.get_path(), fn path -> ["-pa", Path.expand(List.to_string(path))] end)

    executable = System.find_executable("elixir")
    assert is_binary(executable)

    {output, code} =
      System.cmd(executable, ["--erl", "+S 2:2"] ++ paths ++ ["--eval", reader],
        env: [{"VM_MANAGER_COLD_STATE", dir}],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "cold-dependency-diagnostics-restored"
  end

  test "a fresh BEAM safely restores active and interrupted guest runtime statuses",
       %{tmp_dir: dir} do
    config = %Config{
      id: "active",
      kernel: "/kernel",
      mode: :attach,
      control_endpoint: "/api.sock",
      guest: %Config.SowerGuest{},
      vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: "/guest.sock"}
    }

    active = %Manager.Definition{
      config: config,
      desired: :running,
      reserved: true,
      boot_id: "host-boot",
      attempt: "active-attempt",
      beam_identity: "previous-controller",
      observed: %Status{config: config, phase: :running_command, running: true, cleanup: :pending}
    }

    interrupted = %{
      active
      | config: %{config | id: "interrupted"},
        observed: %Status{
          phase: :retained,
          result: {:error, {:reconnect_unconfirmed, :econnrefused}},
          cleanup: :unconfirmed
        }
    }

    protocol = %{
      active
      | config: %{config | id: "protocol"},
        observed: %Status{
          phase: :failed,
          result: {:error, {:guest_protocol, {:error, :invalid_exit_status}}}
        }
    }

    session = %{
      active
      | config: %{config | id: "session"},
        observed: %Status{
          phase: :failed,
          result: {:error, :command_cleanup_unconfirmed}
        }
    }

    assert :ok =
             Store.save(dir, %{
               "active" => active,
               "interrupted" => interrupted,
               "protocol" => protocol,
               "session" => session
             })

    reader = """
    {:ok, definitions} = VMManager.Store.load(System.fetch_env!("VM_MANAGER_COLD_STATE"))
    active = definitions["active"]
    "running" = Atom.to_string(active.desired)
    "running_command" = Atom.to_string(active.observed.phase)
    "pending" = Atom.to_string(active.observed.cleanup)
    true = active.reserved
    true = active.observed.running
    "host-boot" = active.boot_id
    "active-attempt" = active.attempt
    "previous-controller" = active.beam_identity
    "/guest.sock" = active.config.vsock.socket
    interrupted = definitions["interrupted"].observed
    "retained" = Atom.to_string(interrupted.phase)
    "unconfirmed" = Atom.to_string(interrupted.cleanup)
    {:error, {reconnect, connection}} = interrupted.result
    "reconnect_unconfirmed" = Atom.to_string(reconnect)
    "econnrefused" = Atom.to_string(connection)
    {:error, {protocol, {:error, event}}} = definitions["protocol"].observed.result
    "guest_protocol" = Atom.to_string(protocol)
    "invalid_exit_status" = Atom.to_string(event)
    {:error, session} = definitions["session"].observed.result
    "command_cleanup_unconfirmed" = Atom.to_string(session)
    IO.puts("cold-runtime-status-restored")
    """

    paths =
      Enum.flat_map(:code.get_path(), fn path -> ["-pa", Path.expand(List.to_string(path))] end)

    executable = System.find_executable("elixir")
    assert is_binary(executable)

    {output, code} =
      System.cmd(executable, ["--erl", "+S 2:2"] ++ paths ++ ["--eval", reader],
        env: [{"VM_MANAGER_COLD_STATE", dir}],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "cold-runtime-status-restored"
  end
end
