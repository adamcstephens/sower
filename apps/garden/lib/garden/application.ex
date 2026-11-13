defmodule Garden.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Starts Garden's local services and, when an endpoint is configured, its client.

  Storage, scheduler, task supervisor and admin socket run independently of
  the server socket. Local retention continues without a configured endpoint.
  """

  use Application
  require Logger

  @impl Application
  def start(_type, _args) do
    Garden.SignalHandler.attach()

    config = Garden.Config.get()

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
      {:ok, pid} ->
        case Garden.ManagedProfiles.sync_local_subscriptions() do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(msg: "Failed to persist local profile policy", error: inspect(reason))
        end

        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
