defmodule Sower.Repo.Migrations.AddNoteToDeploymentEvents do
  use Ecto.Migration

  def change do
    alter table(:deployment_events) do
      add :note, :text
    end
  end
end
