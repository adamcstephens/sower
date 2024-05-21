defmodule Sower.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SowerWeb.Telemetry,
      Sower.Repo,
      {AshAuthentication.Supervisor, otp_app: :sower},
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

  def credential!(name) do
    credential_dir = System.get_env("CREDENTIALS_DIRECTORY")
    credential = System.get_env(name)

    case read_credential(name, credential_dir, credential) do
      {:ok, value} -> value |> String.trim()
      {:error, err} -> raise ~s"unable to load credential #{name}, #{err}"
    end
  end

  defp read_credential(_, nil, cred), do: read_credential(cred)
  defp read_credential(name, dir, nil), do: read_credential(~s"#{dir}/#{name}")
  defp read_credential(_, dir, cred), do: read_credential(~s"#{dir}/#{cred}")
  defp read_credential(path), do: File.read(path)
end
