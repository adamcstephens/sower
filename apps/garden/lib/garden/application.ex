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

    children =
      [
        {Garden.Storage, []},
        {Task.Supervisor, name: Garden.TaskSupervisor},
        {Garden.Image.Supervisor, image_options(config)},
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
    case Garden.Image.Manager.shutdown() do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error(msg: "Image shutdown cleanup incomplete", error: inspect(reason))
    end

    state
  end

  defp image_options(nil), do: []

  defp image_options(%SowerClient.Config{} = config) do
    [
      budgets: [
        vms: config.image_capacity.vms,
        cpus: config.image_capacity.cpus,
        memory: config.image_capacity.memory,
        scratch_bytes: config.image_capacity.scratch_bytes
      ],
      result_limit: config.image_result_limit,
      shutdown_ms: config.image_shutdown_ms
    ]
  end
end
