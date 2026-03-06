defmodule Sower.Orchestration.Subscription do
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Sower.Repo
  alias Sower.Orchestration.{Agent, Deployment, SubscriptionDeployment}

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "subscriptions" do
    field :sid, SowerClient.Sid, autogenerate: true
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

  def list_subscriptions do
    Repo.all(__MODULE__)
    |> Repo.preload([:agent])
  end

  def list_subscriptions_for_agent(%Agent{} = agent) do
    __MODULE__
    |> where([s], s.agent_id == ^agent.id)
    |> Repo.all()
  end

  def get_subscription!(id) do
    Repo.get!(__MODULE__, id)
    |> Repo.preload(:agent)
  end

  def get_subscription_sid!(sid), do: Repo.get_by!(__MODULE__, sid: sid)

  def get_subscription_sid(sid) do
    __MODULE__
    |> Repo.get_by(sid: sid)
  end

  def get_subscription_sid_with_deployments!(sid) do
    subscription = get_subscription_sid!(sid)

    Repo.preload(subscription, [
      :agent,
      deployments:
        from(d in Deployment,
          order_by: [
            desc: fragment("? IS NULL", d.deployed_at),
            desc: d.deployed_at,
            desc: d.inserted_at
          ]
        )
    ])
  end

  def get_subscription_sid_with_deployments(sid) do
    get_subscription_sid(sid)
    |> Repo.preload([
      :agent,
      deployments:
        from(d in Deployment,
          order_by: [
            desc: fragment("? IS NULL", d.deployed_at),
            desc: d.deployed_at,
            desc: d.inserted_at
          ]
        )
    ])
  end

  def get_subscription_sids(sids) when is_list(sids) and length(sids) > 0 do
    query = from(sub in __MODULE__, where: sub.sid in ^sids)

    Repo.all(query)
  end

  def get_subscription_sids(sids) when is_list(sids) and length(sids) == 0 do
    {:error, :no_sids_provided}
  end

  def find_subscription(%Sower.Orchestration.Seed{} = seed) do
    rules_filter =
      Enum.map(seed.tags || [], fn tag ->
        %{key: tag.key, value: tag.value}
      end)

    from(s in __MODULE__,
      where: s.seed_name == ^seed.name,
      where: s.seed_type == ^seed.seed_type,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(?) AS r
            WHERE NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements(?) AS t
              WHERE t->>'key' = r->>'key' AND t->>'value' = r->>'value'
            )
          )
          """,
          s.rules,
          ^rules_filter
        )
    )
    |> Repo.all()
  end

  def create_subscription(attrs \\ %{}) do
    case %__MODULE__{
           org_id: Repo.get_org_id(),
           sid: SowerClient.Sid.generate("sub")
         }
         |> changeset(attrs)
         |> Repo.insert(
           on_conflict: {:replace, [:updated_at, :rules]},
           conflict_target: [:agent_id, :org_id, :seed_name, :seed_type],
           returning: true
         ) do
      {:ok, sub} -> {:ok, Repo.reload(sub)}
      err -> err
    end
  end

  def register_subscription(
        %SowerClient.Orchestration.Subscription{
          seed_name: seed_name,
          seed_type: seed_type,
          rules: rules
        },
        agent_id
      ) do
    case create_subscription(%{
           agent_id: agent_id,
           seed_name: seed_name,
           seed_type: seed_type,
           rules: rules
         }) do
      {:ok, subscription} ->
        {:ok, SowerClient.Orchestration.Subscription.cast!(subscription)}

      {:error, _} = error ->
        error
    end
  end

  def sync_subscriptions(subscriptions, agent_id) do
    Repo.transaction(fn ->
      registered =
        Enum.map(subscriptions, fn sub ->
          case register_subscription(sub, agent_id) do
            {:ok, s} -> s
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      registered_sids = Enum.map(registered, & &1.sid)

      from(s in __MODULE__,
        where: s.agent_id == ^agent_id,
        where: s.sid not in ^registered_sids
      )
      |> Repo.delete_all()

      registered
    end)
  end

  def update_subscription(%__MODULE__{} = subscription, attrs) do
    subscription
    |> changeset(attrs)
    |> Repo.update()
  end

  def delete_subscription(%__MODULE__{} = subscription) do
    Repo.delete(subscription)
  end

  def change_subscription(%__MODULE__{} = subscription, attrs \\ %{}) do
    subscription
    |> Repo.preload(:agent)
    |> changeset(attrs)
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

    def changeset(rule, %SowerClient.Orchestration.Subscription.Rule{} = attrs) do
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
