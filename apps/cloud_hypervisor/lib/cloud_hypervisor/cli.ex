defmodule CloudHypervisor.CLI do
  @moduledoc """
  Native Cloud Hypervisor command construction, without process execution.

  `command/1` renders a launch-only VMM for API configuration; `command/2`
  also renders a shared `CloudHypervisor.Config` for direct boot.
  Virtio-console supports `:off`, `:null`, `:tty`, `:pty`, and `:file`;
  serial additionally supports `:socket`. `command/2` raises `ArgumentError`
  for virtio-console socket mode before constructing the command.
  Values remain individual arguments: do not join this output into a shell
  command.
  """

  alias CloudHypervisor.{Config, Launch}
  alias CloudHypervisor.Config.{CPUs, Disk, LandlockRule, Net, Output, RNG, Vsock}

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

  def command(%Launch{}, %Config{console: %Output{mode: :socket}}) do
    raise ArgumentError, "socket output is supported only for serial"
  end

  def command(%Launch{} = launch, %Config{} = config) do
    {executable, args} = command(launch)

    {executable,
     args ++
       option("--kernel", config.kernel) ++
       option("--initramfs", config.initramfs) ++
       option("--cmdline", config.cmdline) ++
       option("--cpus", cpus(config.cpus)) ++
       option("--memory", memory(config.memory)) ++
       repeated("--disk", Enum.map(config.disks, &disk/1)) ++
       repeated("--net", Enum.map(config.net, &net/1)) ++
       option("--serial", output(config.serial)) ++
       option("--console", output(config.console)) ++
       option("--rng", rng(config.rng)) ++
       option("--vsock", vsock(config.vsock)) ++
       if(config.landlock, do: ["--landlock"], else: []) ++
       repeated("--landlock-rules", Enum.map(config.landlock_rules, &landlock_rule/1))}
  end

  defp repeated(_flag, []), do: []
  defp repeated(flag, values), do: [flag | values]

  defp cpus(nil), do: nil
  defp cpus(%CPUs{} = cpus), do: "boot=#{cpus.boot_vcpus},max=#{cpus.max_vcpus}"
  defp memory(nil), do: nil
  defp memory(bytes), do: "size=#{bytes}"

  defp disk(%Disk{} = disk) do
    "path=" <>
      disk.path <>
      readonly(disk.readonly) <> image_type(disk.image_type)
  end

  defp net(%Net{} = net), do: "tap=#{net.tap},mac=#{net.mac}"

  defp readonly(nil), do: ""
  defp readonly(true), do: ",readonly=on"
  defp readonly(false), do: ",readonly=off"
  defp image_type(nil), do: ""
  defp image_type(:raw), do: ",image_type=raw"
  defp output(nil), do: nil
  defp output(%Output{mode: :file} = output), do: "file=" <> output.file
  defp output(%Output{mode: :socket} = output), do: "socket=" <> output.socket
  defp output(%Output{} = output), do: Atom.to_string(output.mode)
  defp rng(nil), do: nil
  defp rng(%RNG{} = rng), do: "src=" <> rng.src
  defp vsock(nil), do: nil
  defp vsock(%Vsock{} = vsock), do: "cid=#{vsock.cid},socket=#{vsock.socket}"
  defp landlock_rule(%LandlockRule{} = rule), do: "path=#{rule.path},access=#{rule.access}"

  defp option(flag, value, prefix \\ "")
  defp option(_flag, nil, _prefix), do: []
  defp option(flag, value, prefix), do: [flag, prefix <> value]

  defp seccomp(true), do: "true"
  defp seccomp(false), do: "false"
  defp seccomp(:log), do: "log"
  defp seccomp(:errno), do: "errno"
end
