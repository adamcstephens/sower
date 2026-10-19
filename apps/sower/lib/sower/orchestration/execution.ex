defmodule Sower.Orchestration.Execution do
  use Sower.Schema

  schema "executions" do
    field :sid, :string
    field :run_sid, :string
    field :org_id, Ecto.UUID
    field :actor_sid, :string
    field :request, :map
    field :state, :string, default: "queued"
    field :queue_reason, :string
    belongs_to :garden, Sower.Orchestration.Garden
    field :session, :string
    field :queue_expires_at, :utc_datetime_usec
    field :deadline_at, :utc_datetime_usec
    field :cancel_pending, :boolean, default: false
    field :result, :map
    field :cursor, :integer, default: 0
    field :attempt, :integer, default: 0
    field :log_bytes, :integer, default: 0
    field :dropped_log_bytes, :integer, default: 0
    timestamps()
  end
end

defmodule Sower.Orchestration.Executions.Builder do
  use Sower.Schema
  @primary_key false
  schema "execution_builders" do
    belongs_to :garden, Sower.Orchestration.Garden, primary_key: true
    field :org_id, Ecto.UUID
    field :session, :string
    field :capability, :map
    field :expires_at, :utc_datetime_usec
  end
end

defmodule Sower.Orchestration.Executions.Event do
  use Sower.Schema

  schema "execution_events" do
    belongs_to :execution, Sower.Orchestration.Execution
    field :org_id, Ecto.UUID
    field :sequence, :integer
    field :payload, :map
  end
end
