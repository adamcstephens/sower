defmodule Sower.Repo.Migrations.AddMoreSids do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add :sid, :string, null: false
    end

    alter table(:nix_caches) do
      add :sid, :string, null: false
    end
  end
end
