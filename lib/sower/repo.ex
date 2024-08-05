defmodule Sower.Repo do
  use Ecto.Repo,
    otp_app: :sower,
    adapter: Ecto.Adapters.Postgres

  def init(_context, config) do
    {:ok, Keyword.merge(config, Application.get_env(:sower, :database, []))}
  end
end
