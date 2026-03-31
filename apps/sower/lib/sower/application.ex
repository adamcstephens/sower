defmodule Sower.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: Sower.ClusterSupervisor]]},
      SowerWeb.Telemetry,
      Sower.Vault,
      Sower.Repo,
      Sower.Forge.Oauth,
      Sower.Forge.WebhookStorage,
      {Finch, name: Sower.Finch},
      {Phoenix.PubSub, name: Sower.PubSub},
      SowerWeb.Presence,
      {Durable, repo: Sower.Repo, queues: %{default: [concurrency: 10]}},
      {Task.Supervisor, name: Sower.TaskSupervisor},
      Sower.Orchestration.StaleDeploymentFinalizer,
      SowerWeb.Endpoint,
      :systemd.ready()
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
