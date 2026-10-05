defmodule CloudHypervisor do
  @moduledoc """
  Isolated Cloud Hypervisor library.

  `CloudHypervisor.Config` is the shared typed direct-boot VM contract, including
  byte-valued memory, CPU counts, local disks, serial/console, RNG, vsock device,
  and Landlock rules. `CloudHypervisor.Launch` keeps executable selection and
  VMM-wide settings separate.

  `CloudHypervisor.CLI.command/2` renders launch and VM configuration as native
  executable/argv output. `command/1` renders a launch-only VMM for subsequent
  API configuration. Neither invokes a shell or starts a process.

  `CloudHypervisor.API.create/2` accepts the same Config. The explicitly
  socket-addressed API also provides ping/boot/info/shutdown/delete and VMM
  shutdown. Reads return typed results; errors distinguish HTTP, transport,
  and response decoding failures. Requests have finite timeouts and no retries.

  This application has no application supervisor or VMM process ownership.

  From `apps/cloud_hypervisor`, run `mix compile --warnings-as-errors` and
  `mix test` independently of the umbrella services. Use `MIX_ENV=test mix run`
  for runtime checks: the shared development runtime configuration expects
  garden/server modules. The existing `checks.x86_64-linux.mix` Nix derivation
  checks umbrella formatting using the packaged dependencies.

  Both projections have been exercised with disposable no-NIC CH 53 guests:
  matching effective configuration, two CPUs, 256 MiB, raw writable disk
  readback, RNG, and vsock device configuration, with seccomp and Landlock
  enabled. CH applies Landlock at different stages: direct CLI launch also
  restricts startup threads, whereas API create restricts the VM thread after
  launch. Equivalent guest configuration does not imply identical restrictions
  on every VMM thread.
  """
end
