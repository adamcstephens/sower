defmodule CloudHypervisor.Launch do
  @moduledoc """
  Executable selection and VMM-wide launch settings for Cloud Hypervisor 53.

  Guest devices, boot payloads, memory, CPUs, and Landlock belong to VM
  configuration, not this contract. API and event-monitor sockets/files are
  path-based; inherited file descriptors are not supported.

  `seccomp` accepts `true`, `false`, `:log`, or `:errno`. `verbosity` is the
  number of native `-v` flags (the binary has no long verbosity flag).
  Optional logging settings preserve the binary's defaults when omitted.
  `log_format` uses Cloud Hypervisor's native token syntax.

  `exit_on_guest_shutdown: false` keeps the VMM alive after guest shutdown;
  it does not prevent an explicit API VMM shutdown.

  Paths used in native `path=...` options must not contain commas, which
  Cloud Hypervisor interprets as option separators. This module does not
  create paths, open files, launch processes, or own their cleanup.
  """

  use TypedStruct

  typedstruct do
    field :executable, String.t(), default: "cloud-hypervisor"
    field :api_socket, String.t()
    field :seccomp, boolean() | :log | :errno, default: true
    field :log_file, String.t()
    field :log_format, String.t()
    field :verbosity, non_neg_integer(), default: 0
    field :event_monitor, String.t()
    field :exit_on_guest_shutdown, boolean(), default: true
  end
end
