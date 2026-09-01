defmodule Sower.Repo.Migrations.AddPolicyToGardens do
  use Ecto.Migration

  def change do
    alter table(:gardens) do
      add :policy, :map
      add :timezone, :string
    end
  end
end
