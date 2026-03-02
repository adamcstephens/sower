defmodule Sower.Repo.Migrations.AddLastDispatchedAtToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :last_dispatched_at, :utc_datetime_usec
    end

    create index(:deployments, [:result, :last_dispatched_at])
  end
end
