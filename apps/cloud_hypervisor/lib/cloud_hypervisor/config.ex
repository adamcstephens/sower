defmodule CloudHypervisor.Config do
  @moduledoc """
  Direct-boot VM configuration for Cloud Hypervisor 53 on x86_64 Linux.

  `kernel` is required. `memory` is bytes, rendered as an unsuffixed byte count
  on the CLI and an integer API `memory.size`. CPU configuration requires both
  boot and maximum counts. Omitted settings retain native CH defaults, not
  library copies of those defaults; `false` is never treated as omission.

  Disks are local image paths. `image_type: :raw` forces raw interpretation;
  omission permits CH autodetection. `readonly` is optional and uses CLI
  `on|off` versus JSON booleans. CLI devices/rules are multiple values after
  one flag; API devices/rules are arrays. No network devices are configured.

  Serial and virtio-console share `Output` modes. File/socket modes require
  their corresponding path. RNG configuration requires a source path; omission
  retains CH's default RNG. Vsock configures a device, not a stream connection.

  Landlock uses a CLI presence flag versus API `landlock_enable`; explicit
  `false` therefore omits the CLI flag. Rules use native `r`, `w`, or `rw`
  access strings. Empty device/rule lists are omitted on both surfaces.
  Paths inside CLI comma-separated options cannot contain commas. This subset
  does not escape native option delimiters or validate CH's resource constraints.
  Launch-wide settings belong to `CloudHypervisor.Launch`.
  """

  use TypedStruct

  typedstruct module: CPUs do
    field :boot_vcpus, pos_integer(), enforce: true
    field :max_vcpus, pos_integer(), enforce: true
  end

  typedstruct module: Disk do
    field :path, String.t(), enforce: true
    field :readonly, boolean() | nil
    field :image_type, :raw | nil
  end

  typedstruct module: Output do
    field :mode, :off | :null | :tty | :pty | :file | :socket, enforce: true
    field :file, String.t()
    field :socket, String.t()
  end

  typedstruct module: RNG do
    field :src, String.t(), enforce: true
  end

  typedstruct module: Vsock do
    field :cid, pos_integer(), enforce: true
    field :socket, String.t(), enforce: true
  end

  typedstruct module: LandlockRule do
    field :path, String.t(), enforce: true
    field :access, String.t(), enforce: true
  end

  typedstruct do
    field :kernel, String.t(), enforce: true
    field :initramfs, String.t()
    field :cmdline, String.t()
    field :cpus, CPUs.t()
    field :memory, pos_integer()
    field :disks, [Disk.t()], default: []
    field :serial, Output.t()
    field :console, Output.t()
    field :rng, RNG.t()
    field :vsock, Vsock.t()
    field :landlock, boolean() | nil
    field :landlock_rules, [LandlockRule.t()], default: []
  end

  def to_api(%__MODULE__{} = config) do
    fields([
      {"payload",
       fields([
         {"kernel", config.kernel},
         {"initramfs", config.initramfs},
         {"cmdline", config.cmdline}
       ])},
      {"cpus", cpus(config.cpus)},
      {"memory", memory(config.memory)},
      {"disks", Enum.map(config.disks, &disk/1)},
      {"serial", output(config.serial)},
      {"console", output(config.console)},
      {"rng", rng(config.rng)},
      {"vsock", vsock(config.vsock)},
      {"landlock_enable", config.landlock},
      {"landlock_rules", Enum.map(config.landlock_rules, &landlock_rule/1)}
    ])
  end

  defp fields(pairs),
    do: Map.new(Enum.reject(pairs, fn {_, value} -> is_nil(value) or value == [] end))

  defp cpus(nil), do: nil
  defp cpus(%CPUs{} = cpus), do: %{"boot_vcpus" => cpus.boot_vcpus, "max_vcpus" => cpus.max_vcpus}
  defp memory(nil), do: nil
  defp memory(bytes), do: %{"size" => bytes}

  defp disk(%Disk{} = disk),
    do:
      fields([
        {"path", disk.path},
        {"readonly", disk.readonly},
        {"image_type", image_type(disk.image_type)}
      ])

  defp image_type(nil), do: nil
  defp image_type(:raw), do: "Raw"
  defp output(nil), do: nil

  defp output(%Output{} = output),
    do: fields([{"mode", mode(output.mode)}, {"file", output.file}, {"socket", output.socket}])

  defp mode(:off), do: "Off"
  defp mode(:null), do: "Null"
  defp mode(:tty), do: "Tty"
  defp mode(:pty), do: "Pty"
  defp mode(:file), do: "File"
  defp mode(:socket), do: "Socket"
  defp rng(nil), do: nil
  defp rng(%RNG{} = rng), do: %{"src" => rng.src}
  defp vsock(nil), do: nil
  defp vsock(%Vsock{} = vsock), do: %{"cid" => vsock.cid, "socket" => vsock.socket}
  defp landlock_rule(%LandlockRule{} = rule), do: %{"path" => rule.path, "access" => rule.access}
end
