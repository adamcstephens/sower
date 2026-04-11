defmodule Sower.Repo.Migrations.RemoveLocalSidFromGardens do
  use Ecto.Migration

  def change do
    alter table(:gardens) do
      remove :local_sid, :string
    end
  end
end
