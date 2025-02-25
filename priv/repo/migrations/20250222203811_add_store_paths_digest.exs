defmodule Sower.Repo.Migrations.AddStorePathDigest do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  def up do
    alter table(:store_paths) do
      add :path_digest, :string
    end

    flush()

    query = from(s in Sower.Nix.StorePath, where: is_nil(s.path_digest))

    # re-run all existing paths through to compute digests
    Sower.Repo.all(query, skip_org_id: true)
    |> Enum.each(&Sower.Nix.update_store_path(&1, %{}))

    alter table(:store_paths) do
      modify :path_digest, :string, null: false
    end

    create unique_index(:store_paths, [:path_digest, :org_id])
  end

  def down do
    alter table(:store_paths) do
      remove :path_digest
    end
  end
end
