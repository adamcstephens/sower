defmodule Sower.Orchestration.Subscription do
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
    field :activation_args, {:array, :string}, default: []
    field :reboot_policy, :string, default: "never"
    field :allow_realtime, :boolean, default: false
    embeds_many :rules, __MODULE__.Rule
    embeds_one :window, __MODULE__.Window

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :garden_id,
      :name,
      :seed_name,
      :seed_type,
      :schedule,
      :timezone,
      :activation_args,
      :reboot_policy,
      :allow_realtime
    ])
    |> cast_embed(:rules, with: &__MODULE__.Rule.changeset/2)
    |> cast_embed(:window, with: &__MODULE__.Window.changeset/2)
    |> unique_constraint([:garden_id, :org_id, :name])
  end

  def list_subscriptions do
    Repo.all(__MODULE__)
    |> Repo.preload([:garden])
  end

  def list_subscriptions_for_garden(%Garden{} = garden) do
    __MODULE__
    |> where([s], s.garden_id == ^garden.id)
    |> Repo.all()
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
    seed
    |> find_subscription()
    |> Enum.filter(fn sub -> sub.allow_realtime end)
  end

  def within_window?(%__MODULE__{window: nil}, _now), do: true

  def within_window?(%__MODULE__{window: window}, now) do
    local = DateTime.shift_zone!(now, window.tz)
    day = local |> DateTime.to_date() |> Date.day_of_week() |> day_name()
    time = DateTime.to_time(local)

    day in window.days and
      Time.compare(time, Time.from_iso8601!("#{window.time_start}:00")) != :lt and
      Time.compare(time, Time.from_iso8601!("#{window.time_end}:00")) != :gt
  end

  defp day_name(1), do: "mon"
  defp day_name(2), do: "tue"
  defp day_name(3), do: "wed"
  defp day_name(4), do: "thu"
  defp day_name(5), do: "fri"
  defp day_name(6), do: "sat"
  defp day_name(7), do: "sun"

  def create_subscription(attrs \\ %{}) do
    attrs = Map.put_new_lazy(attrs, :name, fn -> attrs[:seed_name] end)

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
                :activation_args,
                :reboot_policy,
                :allow_realtime,
                :window
              ]},
           conflict_target: [:garden_id, :org_id, :name],
           returning: true
         ) do
      {:ok, sub} -> {:ok, Repo.reload(sub)}
      err -> err
    end
  end

  def register_subscription(%SowerClient.Orchestration.Subscription{} = sub, garden_id) do
    name = sub.name || SowerClient.Sid.generate("sub")

    case create_subscription(%{
           garden_id: garden_id,
           name: name,
           seed_name: sub.seed_name,
           seed_type: sub.seed_type,
           rules: sub.rules,
           schedule: sub.schedule,
           timezone: sub.timezone,
           activation_args: sub.activation_args,
           reboot_policy: sub.reboot_policy,
           allow_realtime: sub.allow_realtime,
           window: sub.window
         }) do
      {:ok, subscription} ->
        {:ok, SowerClient.Orchestration.Subscription.cast!(subscription)}

      {:error, _} = error ->
        error
    end
  end

  def sync_subscriptions(subscriptions, garden_id) do
    Repo.transaction(fn ->
      registered =
        Enum.map(subscriptions, fn sub ->
          case register_subscription(sub, garden_id) do
            {:ok, s} -> s
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      registered_sids = Enum.map(registered, & &1.sid)

      from(s in __MODULE__,
        where: s.garden_id == ^garden_id,
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
      |> validate_required([:days, :time_start, :time_end, :tz])
    end
  end
end
