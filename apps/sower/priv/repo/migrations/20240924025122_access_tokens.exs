defmodule Sower.Repo.Migrations.AccessTokens do
  use Ecto.Migration

  def change do
    create table(:access_tokens) do
      add(:sid, :string, null: false)
      add(:expires_at, :date)
      add(:description, :string, null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:permissions, :map)
      add(:token_hash, :string)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      timestamps()
    end

    create(unique_index(:access_tokens, :sid))
  end
end
