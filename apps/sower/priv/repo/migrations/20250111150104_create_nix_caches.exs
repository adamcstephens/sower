defmodule Sower.Repo.Migrations.CreateNixCaches do
  use Ecto.Migration

  def change do
    create table(:nix_caches) do
      add(:sid, :string, null: false)
      add(:url, :string, null: false)
      add(:public_key, :string, null: false)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      timestamps()
    end

    create(unique_index(:nix_caches, :url))
    create(unique_index(:nix_caches, :sid))
  end
end
