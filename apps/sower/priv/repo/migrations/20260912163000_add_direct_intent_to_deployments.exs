defmodule Sower.Repo.Migrations.AddDirectIntentToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :direct_action, :string
      add :direct_override, :boolean, default: false, null: false
    end
  end
end
