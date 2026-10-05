defmodule CloudHypervisor do
  @moduledoc """
  Isolated Cloud Hypervisor library.

  `CloudHypervisor.Launch` separates executable selection and VMM-wide settings
  from guest configuration. `CloudHypervisor.CLI.command/1` renders native
  executable/argv output without invoking a shell or starting a process.

  `CloudHypervisor.API` provides explicitly socket-addressed ping, native VM
  create/boot/info/shutdown/delete, and VMM shutdown operations. Reads return
  typed results; errors distinguish HTTP, transport, and response decoding
  failures. Requests use finite timeouts without retries or redirects.

  This application has no application supervisor. Shared guest VM configuration
  and caller-supervised VMM processes are not yet implemented.

  From `apps/cloud_hypervisor`, run `mix compile --warnings-as-errors` and
  `mix test` independently of the umbrella services. Use `MIX_ENV=test mix run`
  for runtime checks: the shared development runtime configuration expects
  garden/server modules. The existing `checks.x86_64-linux.mix` Nix derivation
  checks umbrella formatting using the packaged dependencies.
  """
end
