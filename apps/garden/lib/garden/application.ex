defmodule Garden.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Starts Garden's local services and, when an endpoint is configured, its client.

  Local storage, profile reconciliation, retention and admin access work offline.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Garden.SignalHandler.attach()

    config = Garden.Config.get()

    if config,
      do: Garden.Profile.reconcile(config.subscriptions, config.managed_profiles_directory)

    # Only start client-related processes if endpoint is configured
    client_children =
      if config && config.endpoint do
        [
          {Garden.Socket, []}
        ]
      else
        []
      end

    children =
      [
        {Garden.Storage, []},
        Garden.Scheduler,
        {Task.Supervisor, name: Garden.TaskSupervisor},
        # Admin socket starts unconditionally so admin commands work even when
        # the garden has no endpoint / is disconnected.
        {Garden.AdminSocket, []},
        :systemd.ready()
      ] ++ client_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Garden.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, supervisor} ->
        Garden.Scheduler.schedule_retention()
        {:ok, supervisor}

      error ->
        error
    end
  end
end
