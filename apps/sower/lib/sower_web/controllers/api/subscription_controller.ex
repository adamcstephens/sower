defmodule SowerWeb.Api.SubscriptionController do
  @moduledoc "Subscription policy configuration and explicit managed-profile uninstall requests."
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias Sower.Orchestration.{Subscription, ManagedProfile}
  alias SowerWeb.Api.ProfileController
  alias SowerClient.Orchestration.ProfileOperation
  alias OpenApiSpex.Schema

  operation :index,
    operation_id: "ListGardenSubscriptions",
    parameters: [garden: [in: :path, required: true, type: :string]],
    responses: [
      ok:
        {"Subscriptions", "application/json",
         %Schema{
           type: :object,
           properties: %{
             subscriptions: %Schema{type: :array, items: SowerClient.Orchestration.Subscription}
           }
         }}
    ]

  operation :create,
    operation_id: "CreateGardenSubscription",
    parameters: [garden: [in: :path, required: true, type: :string]],
    request_body: {"Subscription", "application/json", SowerClient.Orchestration.Subscription},
    responses: [ok: {"Subscription", "application/json", SowerClient.Orchestration.Subscription}]

  operation :update,
    operation_id: "UpdateGardenSubscription",
    parameters: [
      garden: [in: :path, required: true, type: :string],
      sid: [in: :path, required: true, type: :string]
    ],
    request_body:
      {"Subscription fields", "application/json",
       %Schema{
         type: :object,
         properties: %{
           retention: %Schema{
             anyOf: [SowerClient.Orchestration.ProfileRetention],
             nullable: true,
             "x-struct": SowerClient.Orchestration.ProfileRetention
           }
         }
       }},
    responses: [ok: {"Subscription", "application/json", SowerClient.Orchestration.Subscription}]

  operation :delete,
    operation_id: "DeleteGardenSubscription",
    parameters: [
      garden: [in: :path, required: true, type: :string],
      sid: [in: :path, required: true, type: :string]
    ],
    responses: [
      accepted:
        {"Pending uninstall", "application/json",
         SowerClient.Orchestration.ProfileOperationResult},
      ok:
        {"Completed deletion", "application/json",
         SowerClient.Orchestration.ProfileOperationResult}
    ]

  def index(conn, %{"garden" => identifier}) do
    with {:ok, garden} <- ProfileController.authorize(conn, identifier, :read) do
      json(conn, %{
        subscriptions: Enum.map(Subscription.list_subscriptions_for_garden(garden), &serialize/1)
      })
    else
      {:error, reason} -> ProfileController.error(conn, reason)
    end
  end

  def create(conn, %{"garden" => identifier}) do
    with {:ok, garden} <- ProfileController.authorize(conn, identifier, :write),
         {:ok, subscription} <-
           Subscription.create_subscription(attrs(conn.body_params, garden.id)) do
      json(conn, serialize(subscription))
    else
      {:error, reason} -> ProfileController.error(conn, reason)
    end
  end

  def update(conn, %{"garden" => identifier, "sid" => sid}) do
    with {:ok, garden} <- ProfileController.authorize(conn, identifier, :write),
         %Subscription{garden_id: id, uninstall_pending: false} = subscription
         when id == garden.id <- Subscription.get_subscription_sid(sid),
         {:ok, updated} <-
           Subscription.update_subscription(subscription, attrs(conn.body_params, garden.id)) do
      json(conn, serialize(updated))
    else
      {:error, reason} -> ProfileController.error(conn, reason)
      _ -> ProfileController.error(conn, :not_found)
    end
  end

  def delete(conn, %{"garden" => identifier, "sid" => sid}) do
    with {:ok, garden} <- ProfileController.authorize(conn, identifier, :write),
         %Subscription{garden_id: id} = subscription when id == garden.id <-
           Subscription.get_subscription_sid(sid) do
      if subscription.seed_type in ["package", "devshell"] do
        operation = %ProfileOperation{
          request_id: SowerClient.Sid.generate("pop"),
          action: "uninstall",
          profile_name: subscription.name,
          subscription_sid: subscription.sid,
          preview: false
        }

        case ManagedProfile.request(garden, operation) do
          {:ok, result} -> conn |> put_status(:accepted) |> json(result)
          {:error, reason} -> ProfileController.error(conn, reason)
        end
      else
        case Subscription.delete_subscription(subscription) do
          {:ok, _} ->
            json(conn, %SowerClient.Orchestration.ProfileOperationResult{
              request_id: SowerClient.Sid.generate("pop"),
              status: "completed"
            })

          {:error, reason} ->
            ProfileController.error(conn, reason)
        end
      end
    else
      {:error, reason} -> ProfileController.error(conn, reason)
      _ -> ProfileController.error(conn, :not_found)
    end
  end

  defp attrs(params, garden_id) do
    Map.new(
      [:name, :seed_name, :seed_type, :rules, :policy, :schedule, :timezone, :retention],
      fn key -> {key, Map.get(params, to_string(key))} end
    )
    |> Enum.reject(fn {key, _} -> not Map.has_key?(params, to_string(key)) end)
    |> Map.new()
    |> Map.put(:garden_id, garden_id)
    |> then(fn attrs ->
      case Map.fetch(attrs, :policy) do
        {:ok, policy} when is_map(policy) ->
          Map.put(
            attrs,
            :policy,
            Enum.map(policy, fn {name, rule} -> Map.put(rule, "name", name) end)
          )

        _ ->
          attrs
      end
    end)
  end

  defp serialize(%Subscription{} = subscription) do
    subscription
    |> Map.update!(:policy, fn rules -> Map.new(rules, &{&1.name, &1}) end)
    |> SowerClient.Orchestration.Subscription.cast!()
  end
end
