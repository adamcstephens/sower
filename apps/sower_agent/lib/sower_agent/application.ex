defmodule SowerAgent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: SowerAgent.Worker.start_link(arg)
      {SowerAgent.Client, []},
      {SowerAgent.Storage, []},
      {Task.Supervisor, name: SowerAgent.TaskSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SowerAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
