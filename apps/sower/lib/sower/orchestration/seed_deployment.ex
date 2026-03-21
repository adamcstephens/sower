defmodule Sower.Orchestration.SeedDeployment do
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Sower.Repo
  alias Sower.Orchestration.{Deployment, Seed}

  schema "seed_deployment" do
    belongs_to :seed, Seed
    belongs_to :deployment, Deployment
    field :log, :string
    field :result, Ecto.Enum, values: [:success, :failure]

    field :state, Ecto.Enum,
      values: [:pending, :downloading, :activating, :completed],
      default: :pending

    timestamps()
  end

  @doc false
  def changeset(seed_deployment, attrs) do
    seed_deployment
    |> cast(attrs, [:log, :result, :state])
  end

  def record_seed_status(
        %SowerClient.Orchestration.SeedDeploymentStatus{} = status,
        %Sower.Orchestration.Garden{} = garden
      ) do
    with {:ok, deployment} <- fetch_deployment(status.deployment_sid),
         :ok <- verify_ownership(deployment, garden),
         {:ok, seed_deployment} <- fetch_seed_deployment(deployment.id, status.seed_sid) do
      seed_deployment
      |> changeset(%{state: status.status})
      |> Repo.update(skip_org_id: true)
      |> case do
        {:ok, _} -> {:ok, %{}}
        error -> error
      end
    end
  end

  def record_seed_result(
        %SowerClient.Orchestration.SeedDeploymentResult{} = result,
        %Sower.Orchestration.Garden{} = garden
      ) do
    with {:ok, deployment} <- fetch_deployment(result.deployment_sid),
         :ok <- verify_ownership(deployment, garden),
         {:ok, seed_deployment} <- fetch_seed_deployment(deployment.id, result.seed_sid) do
      attrs = build_update_attrs(seed_deployment, result)

      with {:ok, _seed_deployment} <-
             seed_deployment
             |> changeset(attrs)
             |> Repo.update(skip_org_id: true) do
        {:ok, %{}}
      end
    end
  end

  defp build_update_attrs(seed_deployment, result) do
    log = append_log(seed_deployment.log, result.log)

    case result.result do
      nil -> %{log: log}
      result -> %{log: log, result: result}
    end
  end

  defp append_log(nil, ""), do: nil
  defp append_log(nil, new), do: new
  defp append_log(_existing, nil), do: nil
  defp append_log(existing, ""), do: existing
  defp append_log(existing, new), do: existing <> "\n" <> new

  defp fetch_deployment(deployment_sid) do
    case Repo.get_by(Deployment, sid: deployment_sid) do
      nil -> {:error, :deployment_not_found}
      deployment -> {:ok, deployment}
    end
  end

  defp verify_ownership(deployment, garden) do
    if deployment.garden_id == garden.id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp fetch_seed_deployment(deployment_id, seed_sid) do
    query =
      from sd in __MODULE__,
        join: s in Seed,
        on: s.id == sd.seed_id,
        where: sd.deployment_id == ^deployment_id and s.sid == ^seed_sid

    case Repo.one(query, skip_org_id: true) do
      nil -> {:error, :seed_not_in_deployment}
      seed_deployment -> {:ok, seed_deployment}
    end
  end
end
