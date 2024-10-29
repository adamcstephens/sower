defmodule Sower.ErrorRepo do
  use Ecto.Repo,
    otp_app: :sower,
    adapter: Ecto.Adapters.Postgres

  require Ecto.Query

  @impl true
  def init(_context, config) do
    {:ok, Keyword.merge(config, Application.get_env(:sower, :error_database, []))}
  end
end
