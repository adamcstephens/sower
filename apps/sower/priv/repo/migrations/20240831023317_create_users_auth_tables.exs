defmodule Sower.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users) do
      add :sid, :string, null: false
      add :email, :citext, null: false
      add :name, :string, null: false
      add :oidc_id, :uuid, null: false
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false

      timestamps()
    end

    create table(:users_tokens) do
      add :sid, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(updated_at: false)
    end

    create index(:users_tokens, [:user_id])

    create unique_index(:users, :sid)
    create unique_index(:users, [:email, :org_id])
    create unique_index(:users, [:oidc_id, :org_id])
    create unique_index(:users_tokens, :sid)
    create unique_index(:users_tokens, [:context, :token])
  end
end
