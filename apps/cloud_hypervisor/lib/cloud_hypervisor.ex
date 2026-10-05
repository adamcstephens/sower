defmodule CloudHypervisor do
  @moduledoc """
  Isolated Cloud Hypervisor library.

  `CloudHypervisor.Launch` separates executable selection and VMM-wide settings
  from guest configuration. `CloudHypervisor.CLI.command/1` renders native
  executable/argv output without invoking a shell or starting a process.

  This application has no application supervisor. Unix-socket API access,
  guest VM configuration, and caller-supervised VMM processes are not yet
  implemented. See `CloudHypervisor.Launch` for the supported launch options.

  From `apps/cloud_hypervisor`, run `mix compile --warnings-as-errors` and
  `mix test` independently of the umbrella services. Use `MIX_ENV=test mix run`
  for runtime checks: the shared development runtime configuration expects
  garden/server modules. The existing `checks.x86_64-linux.mix` Nix derivation
  compiles this application, runs its checks, and verifies isolated startup.
  """
end
