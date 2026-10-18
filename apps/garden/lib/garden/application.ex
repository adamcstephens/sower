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
          if(config.builder, do: Garden.Executions),
          Garden.Scheduler,
          {Garden.Socket, []}
        ]
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    children =
      [
        {Garden.Storage, []},
        {Task.Supervisor, name: Garden.TaskSupervisor},
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

  defp vm_options(nil), do: []

  defp vm_options(%SowerClient.Config{} = config) do
    [
      activator_socket: config.activator_socket,
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
