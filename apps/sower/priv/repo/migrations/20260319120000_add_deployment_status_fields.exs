defmodule Sower.Repo.Migrations.AddDeploymentStatusFields do
  use Ecto.Migration

  def up do
    alter table(:seed_deployment) do
      add :state, :string, default: "pending", null: false
    end
  end

  def down do
    alter table(:seed_deployment) do
      remove :state
    end
  end
end
