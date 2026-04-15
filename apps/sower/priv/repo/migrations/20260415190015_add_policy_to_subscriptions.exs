defmodule Sower.Repo.Migrations.AddPolicyToSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :policy, :map
    end
  end
end
