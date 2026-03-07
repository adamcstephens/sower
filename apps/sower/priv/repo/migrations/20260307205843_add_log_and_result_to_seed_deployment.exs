defmodule Sower.Repo.Migrations.AddLogAndResultToSeedDeployment do
  use Ecto.Migration

  def change do
    alter table(:seed_deployment) do
      add :log, :text
      add :result, :string
    end
  end
end
