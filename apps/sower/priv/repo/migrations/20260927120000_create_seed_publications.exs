defmodule Sower.Repo.Migrations.CreateSeedPublications do
  use Ecto.Migration

  def change do
    create table(:seed_publications) do
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false
      add :seed_id, references(:seeds, on_delete: :delete_all), null: false
      add :instance, :string, null: false
      add :project, :string, null: false
      add :seed_name, :string, null: false
      add :seed_type, :string, null: false
      add :job, :string, null: false
      add :branch, :string, null: false
      add :evaluation, :string, null: false
      add :build, :string, null: false
      add :revision, :string, null: false
      add :source_order, :bigint, null: false
      add :tags, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :seed_publications,
             [:org_id, :instance, :project, :job, :evaluation, :build, :seed_name, :seed_type],
             name: :seed_publications_identity_index
           )

    create unique_index(
             :seed_publications,
             [:org_id, :instance, :project, :job, :branch, :source_order, :seed_name, :seed_type],
             name: :seed_publications_order_index
           )

    create index(:seed_publications, [:seed_id])

    create table(:seed_publication_dispatches) do
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false
      add :publication_id, references(:seed_publications, on_delete: :delete_all), null: false
      add :subscription_id, references(:subscriptions, on_delete: :delete_all), null: false
    end

    create unique_index(:seed_publication_dispatches, [:publication_id, :subscription_id])
  end
end
