defmodule Sower.Orchestration.DeploymentLog do
  use TypedStruct
  import Ecto.Query

  alias Sower.Repo
  alias Sower.Orchestration.{Deployment, Garden}
  alias Sower.Orchestration.DeploymentLog.{Buffer, Pool}
  alias SowerClient.Orchestration.SeedDeploymentLog

  typedstruct do
    field :org_id, String.t()
    field :deployment_id, integer()
    field :deployment_sid, String.t()
    field :seed_sid, String.t()
    field :sequence, pos_integer()
    field :output, binary()
    field :owner, pid()
    field :reset?, boolean(), default: false
    field :evicted, list(), default: []
  end

  def list(%Deployment{} = deployment) do
    if Repo.get_org_id() == deployment.org_id and
         deployment.state in [:created, :dispatched, :acknowledged] do
      case Pool.lookup(deployment.org_id, deployment.sid) do
        nil -> []
        owner -> call_owner(fn -> Buffer.list(owner) end, [])
      end
    else
      []
    end
  end

  def record(%SeedDeploymentLog{} = request, %Garden{} = garden)
      when is_integer(request.sequence) and request.sequence > 0 and
             is_binary(request.output) and byte_size(request.output) <= 16_384 do
    cond do
      not String.valid?(request.output) ->
        {:error, :invalid_log_chunk}

      Repo.get_org_id() != garden.org_id ->
        {:error, :deployment_not_found}

      Repo.in_transaction?() ->
        {:error, :transaction_in_progress}

      true ->
        with {:ok, owner} <- find_owner(request, garden) do
          call_owner(
            fn -> Buffer.append(owner, request, garden) end,
            {:error, :buffer_unavailable}
          )
        else
          {:error, _} = error -> error
        end
    end
  end

  def record(%SeedDeploymentLog{}, %Garden{}), do: {:error, :invalid_log_chunk}

  def delete_for_deployment(%Deployment{} = deployment) do
    call_owner(fn -> Pool.delete(deployment) end, :ok)
  end

  defp find_owner(%SeedDeploymentLog{} = request, %Garden{} = garden) do
    case Pool.lookup(garden.org_id, request.deployment_sid) do
      nil -> create_owner(request, garden)
      owner -> {:ok, owner}
    end
  end

  defp create_owner(%SeedDeploymentLog{} = request, %Garden{} = garden) do
    # Only owner creation takes the row lock, shared with terminal cleanup.
    Repo.transaction(fn ->
      deployment =
        from(d in Deployment, where: d.sid == ^request.deployment_sid, lock: "FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(deployment) ->
          Repo.rollback(:deployment_not_found)

        deployment.garden_id != garden.id ->
          Repo.rollback(:unauthorized)

        deployment.state in [:completed, :stale, :canceled] ->
          Repo.rollback(:deployment_terminal)

        true ->
          deployment = Repo.preload(deployment, :seeds)

          if Enum.any?(deployment.seeds, &(&1.sid == request.seed_sid)) do
            case call_owner(fn -> Pool.ensure(deployment) end, {:error, :buffer_unavailable}) do
              {:ok, owner} -> owner
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            Repo.rollback(:seed_not_in_deployment)
          end
      end
    end)
  end

  defp call_owner(fun, unavailable) do
    fun.()
  catch
    :exit, _reason -> unavailable
  end
end
