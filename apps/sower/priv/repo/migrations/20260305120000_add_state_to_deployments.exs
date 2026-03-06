defmodule Sower.Repo.Migrations.AddStateToDeployments do
  use Ecto.Migration

  def up do
    alter table(:deployments) do
      add :state, :string
    end

    # Backfill existing rows
    execute """
    UPDATE deployments
    SET state = CASE
      WHEN result IS NOT NULL THEN 'completed'
      WHEN last_dispatched_at IS NOT NULL THEN 'dispatched'
      ELSE 'created'
    END
    """

    alter table(:deployments) do
      modify :state, :string, null: false
    end

  end

  def down do
    alter table(:deployments) do
      remove :state
    end
  end
end
