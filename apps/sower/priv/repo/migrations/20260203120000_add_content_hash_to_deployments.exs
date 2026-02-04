defmodule Sower.Repo.Migrations.AddContentHashToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :content_hash, :string
    end

    create index(:deployments, [:agent_id, :content_hash])
  end
end
