defmodule Sower.Repo do
  use Ecto.Repo,
    otp_app: :sower,
    adapter: Ecto.Adapters.SQLite3
end
