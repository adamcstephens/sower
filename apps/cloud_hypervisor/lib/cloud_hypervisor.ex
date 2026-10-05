defmodule CloudHypervisor do
  @moduledoc """
  Isolated Cloud Hypervisor library.

  This application has no application supervisor and does not start VMM processes
  or garden/server services. CLI handling, Unix-socket API access, VM configuration,
  and caller-supervised VMM processes are not yet implemented.

  From `apps/cloud_hypervisor`, run `mix compile --warnings-as-errors` and
  `mix test` independently of the umbrella services. Use `MIX_ENV=test mix run`
  for runtime checks: the shared development runtime configuration expects
  garden/server modules. The existing `checks.x86_64-linux.mix` Nix derivation
  compiles this application, runs its checks, and verifies isolated startup.
  """
end
