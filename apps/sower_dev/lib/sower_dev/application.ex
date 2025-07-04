defmodule SowerDev.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: :erl_boot_server,
        start: {:erl_boot_server, :start_link, [[]]}
      }
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SowerDev.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
