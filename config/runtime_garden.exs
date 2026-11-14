import Config

config :req, default_options: [plugins: [SowerClient.Proxy]]

Code.ensure_loaded!(Garden.VM.Network)
Code.ensure_loaded!(Garden.ActivatorClient)

config :garden, Garden.Scheduler, timezone: Garden.Scheduler.get_timezone()

garden = Garden.Config.load()

config :garden,
       Garden.Socket,
       Application.get_env(:garden, Garden.Socket, [])
       |> Keyword.put_new(:mint_opts, protocols: [:http1])

config :garden, :activator_socket, garden.activator_socket

config :vm_manager,
  state_directory: Path.join(garden.state_directory, "vm-manager"),
  budgets: [
    vms: garden.vm_capacity.vms,
    cpus: garden.vm_capacity.cpus,
    memory: garden.vm_capacity.memory,
    scratch_bytes: garden.vm_capacity.scratch_bytes
  ]
