defmodule Sower.Repo.Migrations.CreateNixCaches do
  use Ecto.Migration

  def change do
    create table(:nix_caches) do
      add :url, :string, null: false
      add :public_key, :string, null: false
      add :org_id, references(:organizations, column: :org_id), null: false

      timestamps()
    end

    create unique_index(:nix_caches, [:url])
  end
end
