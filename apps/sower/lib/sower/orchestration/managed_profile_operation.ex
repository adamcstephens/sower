defmodule Sower.Orchestration.ManagedProfileOperation do
  @moduledoc "Durable, garden-scoped operation requests and acknowledged outcomes."
  use Sower.Schema

  schema "managed_profile_operations" do
    field :org_id, Ecto.UUID
    belongs_to :garden, Sower.Orchestration.Garden
    field :request_id, :string
    field :profile_name, :string
    field :action, :string
    field :request, :map
    field :result, :map
    field :status, :string, default: "pending"
    timestamps(type: :utc_datetime_usec)
  end
end
