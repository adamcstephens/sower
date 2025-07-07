defmodule Sower.Orchestration.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "subscriptions" do
    field :sid, Sower.Schema.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    belongs_to :agent, Sower.Orchestration.Agent

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [])
    |> validate_required([])
    |> put_assoc(:agent, attrs.agent)
  end
end
