defmodule Sower.Orchestration.Subscription do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  alias Sower.Orchestration.{Agent, Deployment, SubscriptionDeployment}

  schema "subscriptions" do
    field :sid, SowerClient.Schemas.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    belongs_to :agent, Agent

    many_to_many :deployments, Deployment, join_through: SubscriptionDeployment

    field :seed_name, :string
    field :seed_type, :string
    embeds_many :rules, __MODULE__.Rule

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:agent_id, :seed_name, :seed_type])
    |> cast_embed(:rules, with: &__MODULE__.Rule.changeset/2)
    |> unique_constraint([:agent_id, :org_id, :seed_name, :seed_type])
  end

  defmodule Rule do
    use Ecto.Schema
    import Ecto.Changeset

    @derive {Jason.Encoder, only: [:key, :op, :value]}

    embedded_schema do
      field :key, :string
      field :op, :string
      field :value, :string
    end

    def changeset(rule, %SowerClient.Schemas.Orchestration.Subscription.Rule{} = attrs) do
      changeset(rule, Map.from_struct(attrs))
    end

    def changeset(rule, attrs) do
      attrs =
        case attrs do
          %{op: op} when is_atom(op) -> Map.put(attrs, :op, Atom.to_string(op))
          _ -> attrs
        end

      rule
      |> cast(attrs, [:key, :op, :value])
      |> validate_required([:key, :op, :value])
    end
  end
end
