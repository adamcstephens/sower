defmodule SowerAgent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = SowerAgent.Config.get()

    # Only start client-related processes if endpoint is configured
    client_children =
      if config && config.endpoint do
        [
          SowerAgent.Scheduler,
          {SowerAgent.Client, []}
        ]
      else
        []
      end

    children =
      [
        {SowerAgent.Storage, []},
        {Task.Supervisor, name: SowerAgent.TaskSupervisor},
        :systemd.ready()
      ] ++ client_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SowerAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
