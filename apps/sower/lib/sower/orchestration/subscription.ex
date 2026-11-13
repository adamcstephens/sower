defmodule Sower.Orchestration.Subscription do
  @moduledoc "Subscription selection and policy, retaining managed uninstall tombstones until acknowledgement."
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  require Logger

  alias Sower.Repo
  alias Sower.Orchestration.{Garden, Deployment, SubscriptionDeployment}

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "subscriptions" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    belongs_to :garden, Garden

    many_to_many :deployments, Deployment, join_through: SubscriptionDeployment

    field :name, :string
    field :seed_name, :string
    field :seed_type, :string
    field :schedule, :string
    field :timezone, :string
    field :retention, :map
    field :origin, :string, default: "declared"
    field :configured_retention, :map
    field :retention_config_observed, :boolean, default: false
    field :uninstall_pending, :boolean, default: false
    embeds_many :rules, __MODULE__.Rule, on_replace: :delete
    embeds_many :policy, __MODULE__.PolicyRule, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    attrs = normalize_attrs(attrs)

    subscription
    |> cast(attrs, [
      :garden_id,
      :name,
      :seed_name,
      :seed_type,
      :schedule,
      :timezone,
      :retention,
      :origin,
      :configured_retention,
      :retention_config_observed,
      :uninstall_pending
    ])
    |> cast_embed(:rules, with: &__MODULE__.Rule.changeset/2)
    |> cast_embed(:policy, with: &__MODULE__.PolicyRule.changeset/2)
    |> validate_retention()
    |> unique_constraint([:garden_id, :org_id, :name])
  end

  defp normalize_attrs(attrs) do
    Enum.reduce(
      [
        :garden_id,
        :name,
        :seed_name,
        :seed_type,
        :schedule,
        :timezone,
        :retention,
        :configured_retention,
        :retention_config_observed,
        :uninstall_pending,
        :origin,
        :rules,
        :policy
      ],
      %{},
      fn key, result ->
        case Map.fetch(attrs, key) do
          {:ok, value} ->
            Map.put(result, key, value)

          :error ->
            case Map.fetch(attrs, to_string(key)) do
              {:ok, value} -> Map.put(result, key, value)
              :error -> result
            end
        end
      end
    )
  end

  defp validate_retention(changeset) do
    validate_change(changeset, :retention, fn :retention, retention ->
      if is_map(retention) and map_size(retention) > 0 and
           Enum.all?(retention, fn {key, value} ->
             to_string(key) in ["keep_generations", "keep_days"] and is_integer(value) and
               value >= 0
           end) do
        []
      else
        [retention: "must contain nonnegative keep_generations or keep_days"]
      end
    end)
  end

  def list_subscriptions do
    Repo.all(__MODULE__)
    |> Repo.preload([:garden])
  end

  def list_subscriptions_for_garden(%Garden{} = garden) do
    __MODULE__
    |> where([s], s.garden_id == ^garden.id)
    |> where([s], not s.uninstall_pending)
    |> Repo.all()
  end

  @doc """
  Finds the oldest subscription for a garden and seed identity, regardless of
  its tag rules. Direct deployment and seed warming use the same selection.
  """
  def find_for_garden_seed(%Garden{} = garden, name, seed_type) do
    from(s in __MODULE__,
      where: s.garden_id == ^garden.id and s.seed_name == ^name and s.seed_type == ^seed_type,
      where: not s.uninstall_pending,
      order_by: [asc: s.inserted_at, asc: s.id],
      limit: 1
    )
    |> Repo.one()
  end

  def get_subscription!(id) do
    Repo.get!(__MODULE__, id)
    |> Repo.preload(:garden)
  end

  def get_subscription_sid!(sid), do: Repo.get_by!(__MODULE__, sid: sid)

  def get_subscription_sid(sid) do
    __MODULE__
    |> Repo.get_by(sid: sid)
  end

  def get_subscription_sid_with_deployments!(sid) do
    subscription = get_subscription_sid!(sid)

    Repo.preload(subscription, [
      :garden,
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
      :garden,
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
      where: not s.uninstall_pending,
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

  def find_realtime_subscriptions(%Sower.Orchestration.Seed{} = seed) do
    alias SowerClient.Orchestration.Subscription.Policy

    seed
    |> find_subscription()
    |> Enum.filter(fn sub -> Policy.has_realtime_trigger?(sub.policy) end)
  end

  def create_subscription(attrs \\ %{}) do
    attrs
    |> normalize_attrs()
    |> Map.put(:origin, "operator")
    |> create_owned_subscription()
  end

  defp create_owned_subscription(attrs) do
    attrs = Map.put_new_lazy(attrs, :name, fn -> attrs[:seed_name] end)

    case Repo.get_by(__MODULE__, garden_id: attrs[:garden_id], name: attrs[:name]) do
      %__MODULE__{uninstall_pending: true} ->
        {:error, :uninstall_pending}

      %__MODULE__{seed_type: type, origin: origin}
      when type in ["package", "devshell"] and origin != attrs.origin ->
        {:error, :ownership_conflict}

      %__MODULE__{seed_type: type, seed_name: name}
      when type in ["package", "devshell"] and
             (name != attrs.seed_name or type != attrs.seed_type) ->
        {:error, :ownership_conflict}

      nil ->
        removed =
          attrs.origin == "declared" and
            Repo.exists?(
              from(o in Sower.Orchestration.ManagedProfileOperation,
                where:
                  o.garden_id == ^attrs.garden_id and o.profile_name == ^attrs.name and
                    o.action == "uninstall" and o.status == "completed"
              )
            )

        if removed, do: {:error, :uninstall_pending}, else: insert_subscription(attrs)

      _ ->
        insert_subscription(attrs)
    end
  end

  defp insert_subscription(attrs) do
    case %__MODULE__{
           org_id: Repo.get_org_id(),
           sid: SowerClient.Sid.generate("sub")
         }
         |> changeset(attrs)
         |> Repo.insert(
           on_conflict:
             {:replace,
              [
                :updated_at,
                :seed_name,
                :seed_type,
                :rules,
                :schedule,
                :timezone,
                :retention,
                :configured_retention,
                :retention_config_observed,
                :policy
              ]},
           conflict_target: [:garden_id, :org_id, :name],
           returning: true
         ) do
      {:ok, sub} ->
        sub = Repo.reload(sub)
        broadcast_managed_snapshot(sub.garden_id)
        {:ok, sub}

      err ->
        err
    end
  end

  def register_subscription(%SowerClient.Orchestration.Subscription{} = sub, garden_id) do
    configured =
      if sub.retention do
        sub.retention
        |> Jason.encode!()
        |> Jason.decode!()
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
      end

    existing = Repo.get_by(__MODULE__, garden_id: garden_id, name: sub.name)

    retention =
      case existing do
        %__MODULE__{retention_config_observed: true, configured_retention: ^configured} ->
          existing.retention

        _ ->
          configured
      end

    attrs = %{
      garden_id: garden_id,
      origin: "declared",
      name: sub.name,
      seed_name: sub.seed_name,
      seed_type: sub.seed_type,
      rules: sub.rules,
      schedule: sub.schedule,
      timezone: sub.timezone,
      retention: retention,
      configured_retention: configured,
      retention_config_observed: true,
      policy: policy_to_list(sub.policy)
    }

    case create_owned_subscription(attrs) do
      {:ok, subscription} ->
        castable = Map.update!(subscription, :policy, &policy_list_to_map/1)
        {:ok, SowerClient.Orchestration.Subscription.cast!(castable)}

      {:error, _} = error ->
        error
    end
  end

  def managed_snapshot(%Garden{} = garden) do
    Repo.all(
      from(s in __MODULE__,
        where: s.garden_id == ^garden.id and s.seed_type in ["package", "devshell"]
      )
    )
    |> Enum.map(fn subscription ->
      subscription
      |> Map.update!(:policy, &policy_list_to_map/1)
      |> SowerClient.Orchestration.Subscription.cast!()
    end)
  end

  def broadcast_managed_snapshot(garden_id) do
    garden = Repo.get!(Garden, garden_id)

    Phoenix.PubSub.broadcast(
      Sower.PubSub,
      "managed_profile_dispatch:#{garden.sid}",
      :refresh_managed_subscriptions
    )
  end

  defp policy_list_to_map(rules) when is_list(rules) do
    Map.new(rules, fn rule ->
      name = Map.get(rule, :name) || Map.get(rule, "name") || "unnamed"
      {name, rule}
    end)
  end

  defp policy_to_list(policy) when is_list(policy), do: policy

  defp policy_to_list(policy) when is_map(policy) do
    Enum.map(policy, fn {name, rule} ->
      Map.put(rule, :name, name)
    end)
  end

  def sync_subscriptions(subscriptions, garden_id) do
    Repo.transaction(fn ->
      registered =
        Enum.flat_map(subscriptions, fn sub ->
          case register_subscription(sub, garden_id) do
            {:ok, s} -> [s]
            {:error, :uninstall_pending} -> []
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      registered_sids = Enum.map(registered, & &1.sid)

      from(s in __MODULE__,
        where: s.garden_id == ^garden_id,
        where: s.sid not in ^registered_sids,
        where: s.seed_type not in ["package", "devshell"]
      )
      |> Repo.delete_all()

      registered
    end)
  end

  def update_subscription(%__MODULE__{} = subscription, attrs) do
    subscription = Repo.reload!(subscription)

    attrs =
      attrs
      |> normalize_attrs()
      |> Map.drop([
        :origin,
        :configured_retention,
        :retention_config_observed,
        :uninstall_pending
      ])

    changeset = changeset(subscription, attrs)

    changeset =
      cond do
        subscription.uninstall_pending ->
          add_error(changeset, :name, "has a pending uninstall")

        subscription.seed_type in ["package", "devshell"] and
            get_change(changeset, :name) != nil ->
          add_error(changeset, :name, "cannot rename an owned profile; uninstall it first")

        true ->
          changeset
      end

    case Repo.update(changeset) do
      {:ok, updated} ->
        broadcast_managed_snapshot(updated.garden_id)
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_subscription(%__MODULE__{seed_type: type} = subscription)
      when type in ["package", "devshell"] do
    garden = Repo.get!(Garden, subscription.garden_id)

    operation = %SowerClient.Orchestration.ProfileOperation{
      request_id: SowerClient.Sid.generate("pop"),
      profile_name: subscription.name,
      subscription_sid: subscription.sid,
      action: "uninstall",
      preview: false
    }

    case Sower.Orchestration.ManagedProfile.request(garden, operation) do
      {:ok, _result} -> {:ok, Repo.reload!(subscription)}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_subscription(%__MODULE__{} = subscription), do: Repo.delete(subscription)

  def change_subscription(%__MODULE__{} = subscription, attrs \\ %{}) do
    subscription
    |> Repo.preload(:garden)
    |> changeset(attrs)
  end

  # Schedule catch-up

  def catch_up_overdue_schedules(%Garden{} = garden, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    scheduled_subscriptions = list_scheduled_subscriptions_for_garden(garden)

    overdue =
      Enum.filter(scheduled_subscriptions, fn sub ->
        schedule_is_overdue?(sub, now)
      end)

    if overdue != [] do
      Logger.info(
        msg: "Found overdue scheduled subscriptions",
        garden_sid: garden.sid,
        count: length(overdue),
        subscription_sids: Enum.map(overdue, & &1.sid)
      )
    end

    overdue
  end

  defp list_scheduled_subscriptions_for_garden(%Garden{} = garden) do
    from(s in __MODULE__,
      where: s.garden_id == ^garden.id,
      where: not is_nil(s.schedule),
      preload: [:garden]
    )
    |> Repo.all()
  end

  defp schedule_is_overdue?(%__MODULE__{schedule: schedule, timezone: timezone} = sub, now) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, %{reboot: true}} ->
        false

      {:ok, cron} ->
        naive_now = to_local_naive(now, timezone)

        previous_run =
          Crontab.Scheduler.get_previous_run_date!(cron, naive_now)
          |> from_local_naive(timezone)

        last_deployed = last_successful_deployment_time(sub.id)

        case last_deployed do
          nil -> true
          deployed_at -> DateTime.compare(previous_run, deployed_at) == :gt
        end

      {:error, error} ->
        Logger.warning(
          msg: "Failed to parse schedule for catch-up",
          subscription_sid: sub.sid,
          schedule: schedule,
          error: error
        )

        false
    end
  end

  defp last_successful_deployment_time(subscription_id) do
    from(d in Deployment,
      join: sd in SubscriptionDeployment,
      on: sd.deployment_id == d.id,
      where: sd.subscription_id == ^subscription_id,
      where: d.state == :completed and d.result == :success,
      order_by: [desc: d.deployed_at],
      limit: 1,
      select: d.deployed_at
    )
    |> Repo.one()
  end

  defp to_local_naive(datetime, nil), do: DateTime.to_naive(datetime)
  defp to_local_naive(datetime, "Etc/UTC"), do: DateTime.to_naive(datetime)

  defp to_local_naive(datetime, tz) do
    datetime
    |> DateTime.shift_zone!(tz)
    |> DateTime.to_naive()
  end

  defp from_local_naive(naive, nil), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp from_local_naive(naive, "Etc/UTC"), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp from_local_naive(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
    end
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

  defmodule Window do
    use Ecto.Schema
    import Ecto.Changeset

    @derive {Jason.Encoder, only: [:days, :time_start, :time_end, :tz]}

    embedded_schema do
      field :days, {:array, :string}
      field :time_start, :string
      field :time_end, :string
      field :tz, :string
    end

    def changeset(window, attrs) when is_struct(attrs) do
      changeset(window, Map.from_struct(attrs))
    end

    def changeset(window, attrs) do
      window
      |> cast(attrs, [:days, :time_start, :time_end, :tz])
      |> validate_required([:time_start, :time_end])
    end
  end

  defmodule PolicyRule do
    use Ecto.Schema
    import Ecto.Changeset

    alias Sower.Orchestration.Subscription.Window

    @derive {Jason.Encoder, only: [:name, :actions, :triggers, :window, :confirm]}

    embedded_schema do
      field :name, :string
      field :actions, {:array, :string}
      field :triggers, {:array, :string}
      field :confirm, :boolean, default: false
      embeds_one :window, Window
    end

    def changeset(rule, attrs) when is_struct(attrs) do
      changeset(rule, Map.from_struct(attrs))
    end

    def changeset(rule, attrs) do
      rule
      |> cast(attrs, [:name, :actions, :triggers, :confirm])
      |> cast_embed(:window, with: &Window.changeset/2)
      |> validate_required([:actions])
    end
  end
end
