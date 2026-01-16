defmodule Sower.Repo.Migrations.AddAgentIdToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add(:agent_id, references(:agents, on_delete: :nilify_all))
    end

    create(index(:deployments, [:agent_id]))
  end
end
