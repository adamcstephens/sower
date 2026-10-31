import Config

if config_env() == :dev do
  if Code.ensure_loaded?(Garden.Config) and Code.ensure_loaded?(Garden.Scheduler) do
    config :garden, Garden.Scheduler, timezone: Garden.Scheduler.get_timezone()

    garden =
      Garden.Config.load(%{
        access_token_file: Path.expand("../.dev-api-token", __DIR__),
        endpoint: "http://localhost:7150",
        state_directory: Path.expand("../_build", __DIR__)
      })

    config :vm_manager,
      state_directory: Path.join(garden.state_directory, "vm-manager"),
      activator_socket: garden.activator_socket,
      budgets: [
        vms: garden.vm_capacity.vms,
        cpus: garden.vm_capacity.cpus,
        memory: garden.vm_capacity.memory,
        scratch_bytes: garden.vm_capacity.scratch_bytes
      ]
  end

  if Code.ensure_loaded?(Sower.Config) do
    Sower.Config.load()
  end
end

if config_env() == :test do
  config :vm_manager,
    state_directory:
      Path.join(System.tmp_dir!(), "vm-manager-test-#{System.unique_integer([:positive])}")

  if Code.loaded?(Garden.Config) do
    Garden.Config.load(
      %{
        state_directory:
          Path.join(System.tmp_dir!(), "sower_test_#{System.system_time(:millisecond)}"),
        subscriptions: [
          %{name: "test1", seed_name: "test1", seed_type: "nixos"},
          %{name: "test1", seed_name: "test1", seed_type: "home-manager"}
        ]
      },
      skip_config_file: true,
      validate: false
    )
  end

  if Code.loaded?(SowerCli.Config) do
    SowerCli.Config.load(skip_config_file: true)
  end
end
