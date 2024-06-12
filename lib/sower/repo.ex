defmodule Sower.Repo do
  use AshPostgres.Repo, otp_app: :sower

  # Installs Postgres extensions that ash commonly uses
  def installed_extensions do
    [
      "ash-functions",
      "citext",
      "uuid-ossp"
    ]
  end

  def init(_context, config) do
    {:ok, Keyword.merge(config, Application.get_env(:sower, :database))}
  end
end
