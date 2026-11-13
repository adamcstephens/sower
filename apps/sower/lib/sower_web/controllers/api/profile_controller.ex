defmodule SowerWeb.Api.ProfileController do
  @moduledoc "Organization-authorized managed profile observations and durable operations."
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs
  import Sower.Authorization
  alias Sower.Orchestration.{Garden, Deployment, ManagedProfile}
  alias SowerClient.Orchestration.{ProfileOperation, ProfileOperationResult, GardenSeedProfile}
  alias OpenApiSpex.Schema

  operation :index,
    operation_id: "ListManagedProfiles",
    parameters: [garden: [in: :path, required: true, type: :string]],
    responses: [
      ok:
        {"Profiles", "application/json",
         %Schema{
           type: :object,
           properties: %{profiles: %Schema{type: :array, items: GardenSeedProfile}}
         }}
    ]

  operation :create,
    operation_id: "RequestProfileOperation",
    parameters: [garden: [in: :path, required: true, type: :string]],
    request_body: {"Operation", "application/json", ProfileOperation},
    responses: [accepted: {"Operation result", "application/json", ProfileOperationResult}]

  operation :show,
    operation_id: "GetProfileOperation",
    parameters: [
      garden: [in: :path, required: true, type: :string],
      request_id: [in: :path, required: true, type: :string]
    ],
    responses: [ok: {"Operation result", "application/json", ProfileOperationResult}]

  def index(conn, %{"garden" => identifier}) do
    with {:ok, garden} <- authorize(conn, identifier, :read) do
      json(conn, %{profiles: ManagedProfile.list_for_garden(garden)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, %{"garden" => identifier}) do
    with {:ok, operation} <- ProfileOperation.cast(conn.body_params),
         access =
           if(operation.action == "inspect" or operation.preview == true, do: :read, else: :write),
         {:ok, garden} <- authorize(conn, identifier, access),
         {:ok, result} <- ManagedProfile.request(garden, operation) do
      conn |> put_status(:accepted) |> json(result)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, %{"garden" => identifier, "request_id" => request_id}) do
    with {:ok, garden} <- authorize(conn, identifier, :read),
         {:ok, result} <- ManagedProfile.operation_result(garden, request_id) do
      json(conn, result)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def authorize(conn, identifier, action) do
    token = conn.assigns.access_token
    permission = can(token)
    resource = %Deployment{org_id: token.org_id}

    allowed =
      if action == :read, do: read?(permission, resource), else: create?(permission, resource)

    with true <- allowed,
         {:ok, %Garden{org_id: org_id} = garden} when org_id == token.org_id <-
           Garden.resolve(identifier) do
      {:ok, garden}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  def error(conn, reason) do
    status =
      case reason do
        :unauthorized -> :unauthorized
        :not_found -> :not_found
        :garden_not_found -> :not_found
        :ambiguous_garden -> :conflict
        :request_id_conflict -> :conflict
        _ -> :unprocessable_entity
      end

    conn |> put_status(status) |> json(%{error: inspect(reason)})
  end
end
