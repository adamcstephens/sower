defmodule VMManager.StoreRuntimeTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Manager, Status, Store}

  @moduletag :tmp_dir

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
