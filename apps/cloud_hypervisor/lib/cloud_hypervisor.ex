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

  `CloudHypervisor.Process` owns one caller-supervised VMM, with either CLI
  boot or API create/boot. It exposes a socket-addressed client, bounded API
  readiness, VM state, output, and the actual exit status or terminating signal.
  Guest runtime readiness remains the caller's responsibility.

  Rexec owns and reaps the child process tree, including descendants retaining
  output descriptors. Execution API/vsock sockets live
  in a private directory; caller-supplied execution socket paths are not reused.
  Graceful VMM shutdown and forced process termination are distinct from API
  VM shutdown. Owner death terminates the owned process tree.
  Cleanup failures are explicit and retain execution sockets rather than
  claiming successful teardown. Startup failures remove only empty directories.

  This is process lifecycle ownership, not a production sandbox or system-wide
  crash reconciler. Privileged setup, authority clearing, and external resource
  limits remain the activator/sandbox boundary.

  From `apps/cloud_hypervisor`, run `mix compile --warnings-as-errors` and
  `mix test` independently of the umbrella services. Use `MIX_ENV=test mix run`
  for runtime checks: the shared development runtime configuration expects
  garden/server modules. `checks.x86_64-linux.cloud-hypervisor` builds the library
  against packaged Rexec, runs the isolated lifecycle suite, and packages its
  BEAM artifacts. `checks.x86_64-linux.mix` checks umbrella formatting.

  Both projections have been exercised with disposable no-NIC CH 53 guests:
  matching effective configuration, two CPUs, 256 MiB, raw writable disk
  readback, RNG, and vsock device configuration, with seccomp and Landlock
  enabled. CH applies Landlock at different stages: direct CLI launch also
  restricts startup threads, whereas API create restricts the VM thread after
  launch. Equivalent guest configuration does not imply identical restrictions
  on every VMM thread.
  """
end
