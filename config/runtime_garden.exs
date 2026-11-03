import Config

Code.ensure_loaded!(Garden.VM.Network)
Code.ensure_loaded!(Garden.ActivatorClient)

config :garden, Garden.Scheduler, timezone: Garden.Scheduler.get_timezone()

garden = Garden.Config.load()

config :garden, :activator_socket, garden.activator_socket

config :vm_manager,
  state_directory: Path.join(garden.state_directory, "vm-manager"),
  budgets: [
    vms: garden.vm_capacity.vms,
    cpus: garden.vm_capacity.cpus,
    memory: garden.vm_capacity.memory,
    scratch_bytes: garden.vm_capacity.scratch_bytes
  ]

if boot_id_file = System.get_env("VM_MANAGER_BOOT_ID_FILE") do
  config :vm_manager, boot_id_file: boot_id_file
end
