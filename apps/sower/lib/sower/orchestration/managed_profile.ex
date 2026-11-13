defmodule Sower.Orchestration.ManagedProfile do
  @moduledoc "Durable managed-profile observations and explicit operation intents, independent of subscription observations."
  use Sower.Schema
  import Ecto.Query
  alias Sower.Repo
  alias Sower.Orchestration.{Garden, Subscription, ManagedProfileOperation}
  alias SowerClient.Orchestration.{GardenSeedProfile, ProfileOperation, ProfileOperationResult}

  @warning "External services are not stopped or restarted. Published paths will disappear; release pins only after external consumers have transitioned. Releasing roots does not immediately reclaim disk space."

  schema "managed_profiles" do
    field :org_id, Ecto.UUID
    belongs_to :garden, Garden
    field :name, :string
    field :snapshot, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    field :uninstall_pending, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  def list_for_garden(%Garden{} = garden) do
    Repo.all(from(p in __MODULE__, where: p.garden_id == ^garden.id, order_by: p.name))
    |> Enum.map(&profile(&1, garden))
  end

  def get_for_garden(%Garden{} = garden, name) do
    case Repo.get_by(__MODULE__, garden_id: garden.id, name: name) do
      nil -> nil
      row -> profile(row, garden)
    end
  end

  defp profile(%__MODULE__{} = row, %Garden{} = garden) do
    snapshot =
      if row.uninstall_pending and row.snapshot["lifecycle_status"] != "uninstall_blocked",
        do: Map.put(row.snapshot, "lifecycle_status", "uninstall_pending"),
        else: row.snapshot

    snapshot
    |> Map.put("observed_at", row.observed_at && DateTime.to_iso8601(row.observed_at))
    |> Map.put("stale", is_nil(row.observed_at) or not Garden.managed_profiles_supported?(garden))
    |> GardenSeedProfile.cast!()
  end

  def observe(%Garden{} = garden, profiles) do
    Enum.each(profiles, fn profile ->
      if profile.managed do
        row =
          Repo.get_by(__MODULE__, garden_id: garden.id, name: profile.name) ||
            %__MODULE__{org_id: garden.org_id, garden_id: garden.id, name: profile.name}

        row
        |> Ecto.Changeset.change(snapshot: json_map(profile), observed_at: DateTime.utc_now())
        |> Repo.insert_or_update!()
      end
    end)

    notify(garden)
    :ok
  end

  def request(%Garden{} = garden, %ProfileOperation{} = operation) do
    operation = %{operation | request_id: operation.request_id || SowerClient.Sid.generate("pop")}

    outcome =
      Repo.transaction(fn ->
        Repo.one!(from(g in Garden, where: g.id == ^garden.id, lock: "FOR UPDATE"))

        existing =
          Repo.get_by(ManagedProfileOperation,
            garden_id: garden.id,
            request_id: operation.request_id
          )

        pending_uninstall =
          if operation.action == "uninstall" and operation.preview != true do
            Repo.one(
              from(o in ManagedProfileOperation,
                where:
                  o.garden_id == ^garden.id and o.profile_name == ^operation.profile_name and
                    o.action == "uninstall" and o.status != "completed",
                limit: 1
              )
            )
          end

        cond do
          existing && not same_request?(existing, operation) ->
            {:error, :request_id_conflict}

          existing ->
            {:ok, ProfileOperationResult.cast!(existing.result)}

          pending_uninstall ->
            {:ok, ProfileOperationResult.cast!(pending_uninstall.result)}

          true ->
            with {:ok, addressed} <- address_uninstall(garden, operation) do
              new_request(garden, addressed)
            else
              {:error, reason} -> {:error, reason}
            end
        end
      end)

    case outcome do
      {:ok, {:ok, result}} ->
        if result.status == "pending" and result.request_id == operation.request_id do
          persisted =
            Repo.get_by!(ManagedProfileOperation,
              garden_id: garden.id,
              request_id: result.request_id
            )

          dispatch(garden, ProfileOperation.cast!(persisted.request))
          Subscription.broadcast_managed_snapshot(garden.id)
          notify(garden)
        end

        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_request?(%ManagedProfileOperation{} = existing, %ProfileOperation{} = operation) do
    operation =
      if operation.action == "uninstall" and is_nil(operation.subscription_sid),
        do: %{operation | subscription_sid: existing.request["subscription_sid"]},
        else: operation

    existing.request == json_map(operation)
  end

  defp address_uninstall(
         garden,
         %ProfileOperation{action: "uninstall", preview: preview} = operation
       )
       when preview != true do
    subscription = Repo.get_by(Subscription, garden_id: garden.id, name: operation.profile_name)
    owned = Repo.get_by(__MODULE__, garden_id: garden.id, name: operation.profile_name)
    sid = (subscription && subscription.sid) || (owned && owned.snapshot["subscription_sid"])

    cond do
      is_nil(sid) ->
        {:error, :ownership_unknown}

      operation.subscription_sid && operation.subscription_sid != sid ->
        {:error, :ownership_conflict}

      true ->
        {:ok, %{operation | subscription_sid: sid}}
    end
  end

  defp address_uninstall(_garden, operation), do: {:ok, operation}

  defp new_request(garden, %ProfileOperation{action: "inspect"} = operation) do
    case get_for_garden(garden, operation.profile_name) do
      nil ->
        {:error, :not_found}

      profile ->
        {:ok,
         %ProfileOperationResult{
           request_id: operation.request_id,
           status: "completed",
           profile: profile
         }}
    end
  end

  defp new_request(garden, %ProfileOperation{preview: true} = operation) do
    case get_for_garden(garden, operation.profile_name) do
      nil ->
        case Repo.get_by(Subscription, garden_id: garden.id, name: operation.profile_name) do
          %Subscription{seed_type: type} when type in ["package", "devshell"] ->
            {:ok,
             %ProfileOperationResult{
               request_id: operation.request_id,
               profile_name: operation.profile_name,
               status: "preview",
               affected_generations: [],
               warning:
                 @warning <>
                   " No successful profile inventory has been observed; affected generations are unknown."
             }}

          _ ->
            {:error, :not_found}
        end

      profile ->
        {:ok,
         %ProfileOperationResult{
           request_id: operation.request_id,
           profile_name: operation.profile_name,
           status: "preview",
           profile: profile,
           affected_generations: profile.generations,
           warning: @warning
         }}
    end
  end

  defp new_request(garden, operation) do
    if "managed_profiles_v1" in Repo.reload!(garden).capabilities do
      result = %ProfileOperationResult{
        request_id: operation.request_id,
        profile_name: operation.profile_name,
        status: "pending",
        warning: if(operation.action == "uninstall", do: @warning)
      }

      case Repo.transaction(fn ->
             if operation.action == "uninstall" do
               from(s in Subscription,
                 where:
                   s.garden_id == ^garden.id and s.name == ^operation.profile_name and
                     s.seed_type in ["package", "devshell"]
               )
               |> Repo.update_all(set: [uninstall_pending: true])

               row =
                 Repo.get_by(__MODULE__, garden_id: garden.id, name: operation.profile_name) ||
                   %__MODULE__{
                     org_id: garden.org_id,
                     garden_id: garden.id,
                     name: operation.profile_name,
                     snapshot: %{
                       "name" => operation.profile_name,
                       "subscription_sid" => operation.subscription_sid,
                       "managed" => true,
                       "profile_path" => nil,
                       "generations" => []
                     }
                   }

               row
               |> Ecto.Changeset.change(
                 uninstall_pending: true,
                 snapshot: Map.put(row.snapshot, "lifecycle_status", "uninstall_pending")
               )
               |> Repo.insert_or_update!()
             end

             Repo.insert!(%ManagedProfileOperation{
               org_id: garden.org_id,
               garden_id: garden.id,
               request_id: operation.request_id,
               profile_name: operation.profile_name,
               action: operation.action,
               request: json_map(operation),
               result: json_map(result)
             })

             result
           end) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :managed_profiles_unsupported}
    end
  end

  defp dispatch(garden, %ProfileOperation{action: "stage"} = operation) do
    if Garden.managed_profiles_supported?(garden) do
      subscription =
        Repo.get_by(Subscription,
          garden_id: garden.id,
          sid: operation.subscription_sid,
          name: operation.profile_name,
          uninstall_pending: false
        )

      outcome =
        case subscription do
          nil ->
            {:error, :subscription_not_found}

          sub ->
            Sower.Orchestration.Deployment.deploy_subscription(sub,
              action: :stage,
              seed_sid: operation.seed_sid,
              request_id: operation.request_id,
              force: true
            )
        end

      case outcome do
        {:error, reason} ->
          acknowledge(garden, %ProfileOperationResult{
            request_id: operation.request_id,
            status: "failed",
            error: inspect(reason)
          })

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp dispatch(garden, operation) do
    Phoenix.PubSub.broadcast(
      Sower.PubSub,
      "managed_profile_dispatch:#{garden.sid}",
      {:profile_operation, operation}
    )
  end

  def pending(%Garden{} = garden) do
    Repo.all(
      from(o in ManagedProfileOperation,
        where:
          o.garden_id == ^garden.id and
            (o.status == "pending" or (o.action == "uninstall" and o.status != "completed")),
        order_by: o.id
      )
    )
    |> Enum.map(&ProfileOperation.cast!(&1.request))
  end

  def operation_result(%Garden{} = garden, request_id) do
    case Repo.get_by(ManagedProfileOperation, garden_id: garden.id, request_id: request_id) do
      nil -> {:error, :not_found}
      operation -> {:ok, ProfileOperationResult.cast!(operation.result)}
    end
  end

  def complete_stage(%Garden{} = garden, request_id, seed_result) do
    case Repo.get_by(ManagedProfileOperation,
           garden_id: garden.id,
           request_id: request_id,
           action: "stage"
         ) do
      nil ->
        {:error, :not_found}

      operation ->
        success = seed_result in [:success, "success"]

        acknowledge(garden, %ProfileOperationResult{
          request_id: request_id,
          profile_name: operation.profile_name,
          status: if(success, do: "completed", else: "failed"),
          error: if(success, do: nil, else: to_string(seed_result))
        })
    end
  end

  def replay_stage(%Garden{} = garden, %ProfileOperation{action: "stage"} = operation) do
    case Repo.get_by(Sower.Orchestration.Deployment,
           garden_id: garden.id,
           request_id: operation.request_id
         ) do
      nil -> dispatch(garden, operation)
      %{result: nil} -> :ok
      deployment -> complete_stage(garden, operation.request_id, deployment.result)
    end
  end

  def acknowledge(%Garden{} = garden, %ProfileOperationResult{} = result) do
    Repo.transaction(fn ->
      operation =
        Repo.one(
          from(o in ManagedProfileOperation,
            where: o.garden_id == ^garden.id and o.request_id == ^result.request_id,
            lock: "FOR UPDATE"
          )
        )

      case operation do
        nil ->
          Repo.rollback(:not_found)

        %ManagedProfileOperation{status: "completed"} ->
          ProfileOperationResult.cast!(operation.result)

        operation ->
          if (result.profile_name && result.profile_name != operation.profile_name) ||
               (result.profile && result.profile.name != operation.profile_name) do
            Repo.rollback(:profile_mismatch)
          end

          operation
          |> Ecto.Changeset.change(status: result.status, result: json_map(result))
          |> Repo.update!()

          if result.profile, do: observe(garden, [result.profile])

          if operation.action == "uninstall" do
            case result.status do
              "completed" ->
                row = Repo.get_by(__MODULE__, garden_id: garden.id, name: operation.profile_name)

                if row && is_binary(row.snapshot["profile_path"]) do
                  path = row.snapshot["profile_path"]

                  from(g in Sower.Orchestration.GardenSeedGeneration,
                    join: p in Sower.Orchestration.NixProfile,
                    on: p.id == g.profile_id,
                    where: g.garden_id == ^garden.id and g.managed and p.profile_path == ^path
                  )
                  |> Repo.delete_all()
                end

                from(s in Subscription,
                  where:
                    s.garden_id == ^garden.id and s.name == ^operation.profile_name and
                      s.uninstall_pending
                )
                |> Repo.delete_all()

                from(p in __MODULE__,
                  where: p.garden_id == ^garden.id and p.name == ^operation.profile_name
                )
                |> Repo.delete_all()

              "blocked" ->
                row = Repo.get_by!(__MODULE__, garden_id: garden.id, name: operation.profile_name)

                row
                |> Ecto.Changeset.change(
                  snapshot:
                    Map.merge(row.snapshot, %{
                      "lifecycle_status" => "uninstall_blocked",
                      "last_error" => result.error
                    })
                )
                |> Repo.update!()

              _ ->
                :ok
            end
          end

          result
      end
    end)
    |> case do
      {:ok, result} ->
        notify(garden)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notify(garden),
    do:
      Phoenix.PubSub.broadcast(
        Sower.PubSub,
        "managed_profiles:#{garden.sid}",
        :managed_profiles_updated
      )

  defp json_map(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
