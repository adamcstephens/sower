defmodule Sower.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SowerWeb.Telemetry,
      Sower.Repo,
      Sower.ErrorRepo,
      {Phoenix.PubSub, name: Sower.PubSub},
      {Finch, name: Sower.Finch},
      SowerWeb.Endpoint,
      :systemd.ready()
    ]

    :logger.add_handler(:my_sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:file, :line]}
    })

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sower.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SowerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
