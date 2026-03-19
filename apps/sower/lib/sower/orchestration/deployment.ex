defmodule Sower.Orchestration.Deployment do
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Sower.Repo
  alias Sower.Accounts.User
  alias Sower.Orchestration
  alias Sower.Orchestration.{Agent, Seed, Subscription, DeploymentPubSub}

  require Logger

  @default_stale_after_seconds 2 * 60 * 60
  @default_stale_batch_size 100

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "deployments" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    belongs_to :agent, Agent
    belongs_to :parent_deployment, __MODULE__
    has_many :retries, __MODULE__, foreign_key: :parent_deployment_id
    belongs_to :retried_by_user, User

    many_to_many :subscriptions, Subscription, join_through: Orchestration.SubscriptionDeployment

    has_many :seed_deployments, Orchestration.SeedDeployment
    many_to_many :seeds, Seed, join_through: Orchestration.SeedDeployment

    field :deployed_at, :utc_datetime
    field :result, Ecto.Enum, values: [:success, :failure, :partial]

    field :state, Ecto.Enum,
      values: [:created, :dispatched, :acknowledged, :completed, :stale],
      default: :created

    field :last_dispatched_at, :utc_datetime_usec
    field :content_hash, :string
    field :retry_ordinal, :integer
    field :retried_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :deployed_at,
      :result,
      :state,
      :last_dispatched_at,
      :agent_id,
      :content_hash,
      :parent_deployment_id,
      :retried_by_user_id,
      :retry_ordinal,
      :retried_at
    ])
    |> put_assoc(:seeds, Map.get(attrs, :seeds, deployment.seeds))
    |> put_assoc(:subscriptions, Map.get(attrs, :subscriptions, deployment.subscriptions))
    |> validate_number(:retry_ordinal, greater_than: 0)
    |> validate_required([])
  end

  # CRUD

  def list_deployments do
    query =
      from(r in __MODULE__,
        order_by: [
          desc: fragment("? IS NULL", r.deployed_at),
          desc: r.deployed_at,
          desc: r.inserted_at
        ]
      )

    Repo.all(query)
  end

  def list_deployments(%Agent{} = agent, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(d in __MODULE__,
      where: d.agent_id == ^agent.id,
      order_by: [desc: d.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def list_unresolved_deployments_for_agent(%Agent{} = agent, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      from(d in __MODULE__,
        where: d.agent_id == ^agent.id and d.state in [:created, :dispatched, :acknowledged],
        order_by: [
          asc: fragment("COALESCE(?, ?)", d.last_dispatched_at, d.inserted_at),
          asc: d.inserted_at
        ]
      )

    query =
      if is_integer(limit) and limit > 0 do
        from(d in query, limit: ^limit)
      else
        query
      end

    query
    |> Repo.all()
    |> Repo.preload([:subscriptions, seeds: [:tags]])
  end

  def get_deployment!(id), do: Repo.get!(__MODULE__, id)

  def get_deployment_sid!(sid), do: Repo.get_by!(__MODULE__, sid: sid)

  def get_deployment_sid(sid), do: Repo.get_by(__MODULE__, sid: sid)

  def create_deployment(attrs \\ %{}) do
    result =
      %__MODULE__{
        org_id: Repo.get_org_id(),
        sid: SowerClient.Sid.generate("deploy")
      }
      |> changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, deployment} ->
        DeploymentPubSub.broadcast_deployment_change(deployment, :created)

      {:error, _} = error ->
        error
    end
  end

  def update_deployment(%__MODULE__{} = deployment, attrs) do
    result =
      deployment
      |> Repo.preload([:seeds, :subscriptions])
      |> changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_deployment} ->
        DeploymentPubSub.broadcast_deployment_change(updated_deployment, :updated)

      {:error, _} = error ->
        error
    end
  end

  def delete_deployment(%__MODULE__{} = deployment) do
    Repo.delete(deployment)
  end

  def change_deployment(%__MODULE__{} = deployment, attrs \\ %{}) do
    changeset(deployment, attrs)
  end

  # Retry

  def retry_deployment(%__MODULE__{} = deployment, user_id) when is_integer(user_id) do
    Repo.transaction(fn ->
      user = Repo.get(User, user_id, skip_org_id: true)

      if is_nil(user) do
        Repo.rollback(:unauthorized)
      end

      deployment =
        from(d in __MODULE__, where: d.id == ^deployment.id, lock: "FOR UPDATE")
        |> Repo.one()
        |> Repo.preload([:seeds, :subscriptions])

      cond do
        is_nil(deployment) ->
          Repo.rollback(:deployment_not_found)

        user.org_id != deployment.org_id ->
          Repo.rollback(:unauthorized)

        deployment.result not in [:success, :failure] ->
          Repo.rollback(:deployment_not_retryable)

        true ->
          retry_in_progress? =
            from(d in __MODULE__,
              where:
                d.parent_deployment_id == ^deployment.id and
                  d.state in [:created, :dispatched, :acknowledged],
              limit: 1,
              select: d.id
            )
            |> Repo.one()

          if retry_in_progress? do
            Repo.rollback(:retry_in_progress)
          else
            max_retry_ordinal =
              from(d in __MODULE__,
                where: d.parent_deployment_id == ^deployment.id,
                select: max(d.retry_ordinal)
              )
              |> Repo.one() || 0

            attrs = %{
              agent_id: deployment.agent_id,
              content_hash: deployment.content_hash,
              seeds: deployment.seeds,
              subscriptions: deployment.subscriptions,
              parent_deployment_id: deployment.id,
              retried_by_user_id: user_id,
              retry_ordinal: max_retry_ordinal + 1,
              retried_at: DateTime.utc_now(),
              last_dispatched_at: DateTime.utc_now(),
              state: :dispatched
            }

            case create_deployment(attrs) do
              {:ok, retry_deployment} ->
                retry_deployment =
                  Repo.preload(retry_deployment, [:agent, :subscriptions, seeds: [:tags]])

                request_id = SowerClient.Sid.generate("request")

                SowerWeb.Endpoint.broadcast(
                  "agent:#{retry_deployment.agent.sid}",
                  "deployment",
                  deployment_event_payload(retry_deployment, request_id)
                )

                retry_deployment

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end
      end
    end)
  end

  # Replay

  def replay_unresolved_deployments(%Agent{} = agent, opts \\ []) do
    broadcast_fun = Keyword.get(opts, :broadcast_fun, &SowerWeb.Endpoint.broadcast/3)

    request_id_fun =
      Keyword.get(opts, :request_id_fun, fn -> SowerClient.Sid.generate("request") end)

    now = Keyword.get(opts, :now, DateTime.utc_now())

    deployments = list_unresolved_deployments_for_agent(agent)
    mark_deployments_dispatched(deployments, now)

    Enum.each(deployments, fn deployment ->
      payload = deployment_event_payload(deployment, request_id_fun.())
      broadcast_fun.("agent:#{agent.sid}", "deployment", payload)
    end)

    if deployments != [] do
      Logger.info(
        msg: "Replayed unresolved deployments",
        agent_sid: agent.sid,
        deployment_count: length(deployments),
        deployment_sids: Enum.map(deployments, & &1.sid)
      )
    end

    {:ok, deployments}
  end

  # Seed matching

  def match_seed(%Subscription{} = subscription) do
    tags =
      Enum.map(subscription.rules || [], fn rule ->
        %{key: rule.key, value: rule.value}
      end)

    Seed.latest(subscription.seed_name, subscription.seed_type, tags)
  end

  def list_matching_seeds(%Subscription{} = subscription, limit \\ 10) do
    tags =
      Enum.map(subscription.rules || [], fn rule ->
        %{key: rule.key, value: rule.value}
      end)

    Seed.list_matching(subscription.seed_name, subscription.seed_type, tags, limit: limit)
  end

  # Deployment request handling

  def deploy_subscription(%Subscription{} = sub, opts \\ []) do
    subscription = Repo.preload(sub, :agent)

    case subscription.agent do
      nil ->
        {:error, :agent_not_found}

      %Agent{} = agent ->
        request_id = SowerClient.Sid.generate("request")
        {:ok, request_id} = process_deployment(request_id, [subscription], agent, opts)
        {:ok, request_id}
    end
  end

  def request_deployment(%SowerClient.Orchestration.DeploymentRequest{} = request) do
    with {:ok, subs} <- validate_request_subscriptions(request.subscription_sids) do
      do_deployment(request.request_id, subs, force: request.force)
    else
      {:error, _} = err ->
        Logger.error(msg: "Failed to process deployment request", error: IO.inspect(err))
        {:error, :unknown_error}
    end
  end

  def handle_deployment_request(payload, agent) do
    with {:ok, request} <- SowerClient.Orchestration.DeploymentRequest.cast(payload),
         {:ok, subscriptions} <- validate_deployment_request(request, agent.id),
         {:ok, request_id} <-
           process_deployment(request.request_id, subscriptions, agent, force: request.force) do
      {:ok, request_id}
    end
  end

  def process_deployment(request_id, subscriptions, %Agent{} = agent, opts \\ []) do
    Task.Supervisor.start_child(Sower.TaskSupervisor, fn ->
      Repo.put_org_id(agent.org_id)

      Logger.info(
        msg: "Deployment processing started",
        request_id: request_id,
        agent_id: agent.id
      )

      case do_deployment(request_id, subscriptions, opts) do
        {:ok, deployment} ->
          Logger.info(
            msg: "Deployment broadcast successful",
            request_id: request_id,
            deployment_sid: deployment.sid,
            skipped: deployment.skipped
          )

          SowerWeb.Endpoint.broadcast(
            "agent:#{agent.sid}",
            "deployment",
            Map.from_struct(deployment)
          )

        {:error, reason} ->
          Logger.error(
            msg: "Deployment processing failed",
            request_id: request_id,
            reason: to_string(reason)
          )

          SowerWeb.Endpoint.broadcast(
            "agent:#{agent.sid}",
            "deployment:error",
            %{request_id: request_id, reason: to_string(reason)}
          )
      end
    end)

    {:ok, request_id}
  end

  def record_deployment_status(%SowerClient.Orchestration.DeploymentStatus{} = status) do
    case get_deployment_sid(status.deployment_sid) do
      nil ->
        {:error, :deployment_not_found}

      deploy ->
        update_deployment(deploy, %{state: status.status})
    end
  end

  def record_deployment(%SowerClient.Orchestration.DeploymentResult{} = result) do
    case get_deployment_sid(result.deployment_sid) do
      nil ->
        {:error, :deployment_not_found}

      deploy ->
        update_deployment(deploy, %{
          deployed_at: result.deployed_at,
          result: result.result,
          state: :completed
        })
    end
  end

  # Stale deployment finalization

  def finalize_stale_deployments(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, stale_after_seconds())
    batch_size = Keyword.get(opts, :batch_size, stale_batch_size())

    if stale_after_seconds <= 0 or batch_size <= 0 do
      {:ok, 0}
    else
      cutoff = DateTime.add(now, -stale_after_seconds, :second)

      stale_deployments =
        from(d in __MODULE__,
          where: d.state in [:created, :dispatched, :acknowledged],
          where: fragment("COALESCE(?, ?) <= ?", d.last_dispatched_at, d.inserted_at, ^cutoff),
          order_by: [
            asc: fragment("COALESCE(?, ?)", d.last_dispatched_at, d.inserted_at),
            asc: d.inserted_at
          ],
          limit: ^batch_size
        )
        |> Repo.all(skip_org_id: true)

      finalized =
        Enum.reduce(stale_deployments, 0, fn deployment, acc ->
          case finalize_stale_deployment(deployment, now) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        end)

      if finalized > 0 do
        Logger.info(
          msg: "Finalized stale deployments",
          stale_after_seconds: stale_after_seconds,
          batch_size: batch_size,
          finalized_count: finalized
        )
      end

      {:ok, finalized}
    end
  end

  # Private helpers

  defp validate_request_subscriptions(sids) when is_list(sids) and length(sids) > 0 do
    subs = Subscription.get_subscription_sids(sids)
    subs = Repo.preload(subs, :agent)

    if subs == [] do
      {:error, :subscription_not_found}
    else
      {:ok, subs}
    end
  end

  defp validate_request_subscriptions(_), do: {:error, :subscription_not_found}

  defp validate_deployment_request(
         %SowerClient.Orchestration.DeploymentRequest{} = request,
         agent_id
       ) do
    subs = Subscription.get_subscription_sids(request.subscription_sids)

    cond do
      subs == [] ->
        {:error, :subscription_not_found}

      not Enum.all?(subs, &(&1.agent_id == agent_id)) ->
        {:error, :unauthorized}

      true ->
        {:ok, Repo.preload(subs, :agent)}
    end
  end

  defp do_deployment(request_id, subscriptions, opts) do
    force? = Keyword.get(opts, :force, false)
    agent_id = hd(subscriptions).agent_id

    seed_deploys =
      subscriptions
      |> Enum.reduce([], fn sub, acc ->
        case match_seed(sub) do
          nil ->
            acc

          seed ->
            [
              %SowerClient.Orchestration.SeedDeployment{
                seed: seed,
                subscription_sid: sub.sid
              }
              | acc
            ]
        end
      end)

    seeds = Enum.map(seed_deploys, & &1.seed)

    if seeds == [] do
      Logger.warning(
        msg: "No matching seeds found for deployment request",
        request_id: request_id,
        subscription_count: length(subscriptions)
      )

      {:error, :seeds_not_found}
    else
      content_hash = compute_content_hash(seeds)

      Logger.debug(
        msg: "Processing deployment with matched seeds",
        request_id: request_id,
        seed_count: length(seeds),
        content_hash: content_hash
      )

      case find_duplicate_deployment(agent_id, content_hash, force?) do
        {:skip, existing} ->
          existing = Repo.preload(existing, [:seeds])

          Logger.info(
            msg: "Skipping deployment - duplicate found",
            request_id: request_id,
            deployment_sid: existing.sid,
            content_hash: content_hash
          )

          {:ok,
           %SowerClient.Orchestration.Deployment{
             request_id: request_id,
             sid: existing.sid,
             seed_deployments: seed_deploys,
             skipped: true
           }}

        :proceed ->
          Logger.debug(
            msg: "Creating new deployment record",
            request_id: request_id,
            agent_id: agent_id
          )

          case create_deployment(%{
                 agent_id: agent_id,
                 content_hash: content_hash,
                 last_dispatched_at: DateTime.utc_now(),
                 state: :dispatched,
                 seeds: seeds,
                 subscriptions: subscriptions
               }) do
            {:ok, deploy} ->
              Logger.info(
                msg: "Deployment record created successfully",
                request_id: request_id,
                deployment_sid: deploy.sid
              )

              {:ok,
               %SowerClient.Orchestration.Deployment{
                 request_id: request_id,
                 sid: deploy.sid,
                 seed_deployments: seed_deploys,
                 skipped: false
               }}

            {:error, reason} ->
              Logger.error(
                msg: "Failed to create deployment record",
                request_id: request_id,
                reason: inspect(reason)
              )

              {:error, reason}
          end
      end
    end
  end

  defp compute_content_hash(seeds) do
    seeds
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp find_duplicate_deployment(_agent_id, _content_hash, true), do: :proceed

  defp find_duplicate_deployment(agent_id, content_hash, false) do
    query =
      from(d in __MODULE__,
        where:
          d.agent_id == ^agent_id and
            d.content_hash == ^content_hash and
            (d.result == :success or d.state in [:created, :dispatched, :acknowledged]),
        order_by: [desc: d.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> :proceed
      deployment -> {:skip, deployment}
    end
  end

  defp deployment_event_payload(%__MODULE__{} = deployment, request_id) do
    %SowerClient.Orchestration.Deployment{
      request_id: request_id,
      sid: deployment.sid,
      seed_deployments: build_seed_deployments(deployment.seeds, deployment.subscriptions),
      skipped: false
    }
  end

  defp build_seed_deployments(seeds, subscriptions) do
    Enum.map(seeds, fn seed ->
      subscription_sid =
        subscriptions
        |> Enum.find(fn sub ->
          sub.seed_name == seed.name and sub.seed_type == seed.seed_type
        end)
        |> case do
          nil -> nil
          sub -> sub.sid
        end

      %SowerClient.Orchestration.SeedDeployment{
        seed: seed,
        subscription_sid: subscription_sid
      }
    end)
  end

  defp mark_deployments_dispatched([], _dispatched_at), do: :ok

  defp mark_deployments_dispatched(deployments, dispatched_at) do
    ids = Enum.map(deployments, & &1.id)
    now = DateTime.utc_now()

    from(d in __MODULE__,
      where: d.id in ^ids and d.state in [:created, :dispatched, :acknowledged]
    )
    |> Repo.update_all(
      set: [last_dispatched_at: dispatched_at, state: :dispatched, updated_at: now]
    )

    :ok
  end

  defp finalize_stale_deployment(%__MODULE__{} = deployment, now) do
    previous_org_id = Repo.get_org_id()
    Repo.put_org_id(deployment.org_id)

    result =
      case Repo.get(__MODULE__, deployment.id) do
        nil ->
          :ignore

        %__MODULE__{state: state} = unresolved
        when state in [:created, :dispatched, :acknowledged] ->
          update_deployment(unresolved, %{deployed_at: now, result: :failure, state: :stale})

        %__MODULE__{} ->
          :ignore
      end

    Repo.put_org_id(previous_org_id)

    result
  end

  defp stale_after_seconds do
    config = Application.get_env(:sower, Sower.Orchestration, [])
    Keyword.get(config, :stale_after_seconds, @default_stale_after_seconds)
  end

  defp stale_batch_size do
    config = Application.get_env(:sower, Sower.Orchestration, [])
    Keyword.get(config, :stale_batch_size, @default_stale_batch_size)
  end
end
