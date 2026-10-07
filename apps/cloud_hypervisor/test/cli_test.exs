defmodule CloudHypervisor.CLITest do
  use ExUnit.Case, async: true

  alias CloudHypervisor.{CLI, Config, Launch}
  alias CloudHypervisor.Config.Output

  test "default launch leaves optional settings to the binary" do
    assert CLI.command(%Launch{}) == {"cloud-hypervisor", ["--seccomp", "true"]}
  end

  test "renders native options without splitting or shell quoting values" do
    launch = %Launch{
      executable: "/opt/CH binary/cloud-hypervisor",
      api_socket: "/tmp/api socket;echo.sock",
      seccomp: :errno,
      log_file: "/tmp/log file",
      log_format: "{level}: {msg}",
      verbosity: 2,
      event_monitor: "/tmp/event file",
      exit_on_guest_shutdown: false
    }

    assert CLI.command(launch) ==
             {launch.executable,
              [
                "--api-socket",
                "path=/tmp/api socket;echo.sock",
                "--seccomp",
                "errno",
                "--log-file",
                "/tmp/log file",
                "--log-format",
                "{level}: {msg}",
                "-v",
                "-v",
                "--event-monitor",
                "path=/tmp/event file",
                "--no-shutdown"
              ]}
  end

  test "encodes each supported seccomp mode" do
    for {mode, value} <- [{true, "true"}, {false, "false"}, {:log, "log"}, {:errno, "errno"}] do
      assert CLI.command(%Launch{seccomp: mode}) ==
               {"cloud-hypervisor", ["--seccomp", value]}
    end
  end

  test "direct boot rejects virtio-console socket mode rather than substituting a mode" do
    config = %Config{kernel: "/kernel", console: %Output{mode: :socket, socket: "/console"}}

    assert_raise ArgumentError, fn ->
      CLI.command(%Launch{}, config)
    end
  end
end
