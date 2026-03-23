defmodule Sower.Repo.Migrations.AddScheduleToSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :schedule, :string
      add :timezone, :string
    end
  end
end
