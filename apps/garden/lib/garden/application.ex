defmodule Garden.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    Garden.SignalHandler.attach()

    config = Garden.Config.get()

    # Only start client-related processes if endpoint is configured
    client_children =
      if config && config.endpoint do
        [
          Garden.Scheduler,
          {Garden.Socket, []}
        ]
      else
        []
      end

    work_store_children =
      if :os.type() == {:unix, :linux},
        do: [{Garden.WorkStore, work_store_options(config)}],
        else: []

    children =
      [
        {Garden.Storage, []},
        {Task.Supervisor, name: Garden.TaskSupervisor}
      ] ++
        work_store_children ++
        [
          {Garden.VM.Supervisor, vm_options(config)},
          # Admin socket starts unconditionally so admin commands work even when
          # the garden has no endpoint / is disconnected.
          {Garden.AdminSocket, []},
          :systemd.ready()
        ] ++ client_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Garden.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl Application
  def prep_stop(state) do
    case Garden.VM.Manager.shutdown() do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error(msg: "VM shutdown cleanup incomplete", error: inspect(reason))
    end

    state
  end

  defp work_store_options(nil) do
    [
      name: Garden.WorkStore,
      root: Path.join(SowerClient.Config.default_state_dir(), "work-store")
    ]
  end

  defp work_store_options(%SowerClient.Config{} = config) do
    [
      name: Garden.WorkStore,
      root: config.work_store_directory || Path.join(config.state_directory, "work-store"),
      nix: config.work_store_nix,
      output_bytes: config.work_store_output_bytes,
      cache_bytes: config.work_store_cache_bytes,
      staging_bytes: config.work_store_staging_bytes,
      transfer_bytes: config.work_store_transfer_bytes,
      max_transfers: config.work_store_max_transfers
    ]
  end

  defp vm_options(nil), do: []

  defp vm_options(%SowerClient.Config{} = config) do
    [
      budgets: [
        vms: config.vm_capacity.vms,
        cpus: config.vm_capacity.cpus,
        memory: config.vm_capacity.memory,
        scratch_bytes: config.vm_capacity.scratch_bytes
      ],
      result_limit: config.vm_result_limit,
      shutdown_ms: config.vm_shutdown_ms
    ]
  end
end
