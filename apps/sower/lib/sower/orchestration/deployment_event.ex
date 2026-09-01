defmodule Sower.Orchestration.DeploymentEvent do
  use Sower.Schema
  import Ecto.Changeset

  alias Sower.Repo
  alias Sower.Orchestration.Deployment

  schema "deployment_events" do
    belongs_to :deployment, Deployment
    field :org_id, Ecto.UUID
    field :event, Ecto.Enum, values: [:created, :canceled]

    field :reason, Ecto.Enum,
      values: [
        :user_triggered,
        :schedule_triggered,
        :realtime_triggered,
        :retry,
        :user_retry,
        :poll_on_connect,
        :superseded,
        :stale,
        :direct_triggered,
        :direct_override
      ]

    field :actor_sid, :string
    field :note, :string

    timestamps(updated_at: false)
  end

  def changeset(deployment_event, attrs) do
    deployment_event
    |> cast(attrs, [:deployment_id, :org_id, :event, :reason, :actor_sid, :note])
    |> validate_required([:deployment_id, :org_id, :event, :reason, :actor_sid])
    |> foreign_key_constraint(:deployment_id)
  end

  def record_event(%Deployment{} = deployment, event, reason, actor_sid, note \\ nil) do
    %__MODULE__{
      org_id: Repo.get_org_id()
    }
    |> changeset(%{
      deployment_id: deployment.id,
      event: event,
      reason: reason,
      actor_sid: actor_sid,
      note: note
    })
    |> Repo.insert()
  end
end
