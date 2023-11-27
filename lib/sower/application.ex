defmodule Sower.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      SowerWeb.Telemetry,
      # Start the Ecto repository
      Sower.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Sower.PubSub},
      # Start Finch
      {Finch, name: Sower.Finch},
      Git.Git,
      # Start the Endpoint (http/https)
      SowerWeb.Endpoint
      # Start a worker by calling: Sower.Worker.start_link(arg)
      # {Sower.Worker, arg}
    ]

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
