defmodule SowerDev.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [] ++ start_env()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SowerDev.Supervisor]
    Supervisor.start_link(children, opts)
  end

  if Mix.env() == :dev do
    defp start_env() do
      [
        %{
          id: :erl_boot_server,
          start: {:erl_boot_server, :start_link, [[]]}
        }
      ]
    end
  else
    defp start_env(), do: []
  end
end
