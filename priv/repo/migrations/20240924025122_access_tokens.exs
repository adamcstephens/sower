defmodule Sower.Repo.Migrations.AccessTokens do
  use Ecto.Migration

  def change do
    create table(:access_tokens) do
      add :expires_at, :date
      add :description, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :permissions, :map

      timestamps()
    end
  end
end
