defmodule Sower.Repo.Migrations.AddRealtimeAndWindowToSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :allow_realtime, :boolean, default: false
      add :window, :map
    end
  end
end
