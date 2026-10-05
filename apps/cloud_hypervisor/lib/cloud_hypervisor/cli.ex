defmodule CloudHypervisor.CLI do
  @moduledoc """
  Native Cloud Hypervisor command construction, without process execution.

  `command/1` returns `{executable, argv}` for direct process invocation.
  Values remain individual arguments: do not join this output into a shell
  command. Only VMM launch options are currently rendered; guest configuration
  will extend this entry point rather than introduce another renderer.
  """

  alias CloudHypervisor.Launch

  def command(%Launch{} = launch) do
    args =
      option("--api-socket", launch.api_socket, "path=") ++
        ["--seccomp", seccomp(launch.seccomp)] ++
        option("--log-file", launch.log_file) ++
        option("--log-format", launch.log_format) ++
        List.duplicate("-v", launch.verbosity) ++
        option("--event-monitor", launch.event_monitor, "path=") ++
        if(launch.exit_on_guest_shutdown, do: [], else: ["--no-shutdown"])

    {launch.executable, args}
  end

  defp option(flag, value, prefix \\ "")
  defp option(_flag, nil, _prefix), do: []
  defp option(flag, value, prefix), do: [flag, prefix <> value]

  defp seccomp(true), do: "true"
  defp seccomp(false), do: "false"
  defp seccomp(:log), do: "log"
  defp seccomp(:errno), do: "errno"
end
