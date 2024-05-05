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
end
