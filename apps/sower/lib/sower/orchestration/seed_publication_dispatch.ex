defmodule Sower.Orchestration.SeedPublicationDispatch do
  use Sower.Schema

  schema "seed_publication_dispatches" do
    field :org_id, Ecto.UUID
    belongs_to :publication, Sower.Orchestration.SeedPublication
    belongs_to :subscription, Sower.Orchestration.Subscription
  end
end
