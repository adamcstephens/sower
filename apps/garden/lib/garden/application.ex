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
end
