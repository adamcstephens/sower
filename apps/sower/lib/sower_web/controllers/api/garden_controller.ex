defmodule SowerWeb.Api.GardenController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  import Sower.Authorization

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  action_fallback SowerWeb.Api.FallbackController

  operation(:register,
    operation_id: "RegisterGarden",
    summary: "Register a new garden",
    request_body:
      {"Garden registration params", "application/json", SowerClient.GardenRegistration},
    responses: %{
      created:
        {"Garden registration response", "application/json",
         %Schema{
           type: :object,
           properties: %{
             sid: %Schema{type: :string, description: "Garden SID"},
             oauth_credentials: SowerClient.Auth.OAuthCredentials
           },
           required: [:sid, :oauth_credentials]
         }},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unprocessable_entity:
        {"Validation error", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def register(
        %Plug.Conn{
          body_params: %SowerClient.GardenRegistration{
            name: name,
            public_key: public_key
          }
        } = conn,
        _params
      ) do
    access_token = conn.assigns.access_token

    if can(access_token)
       |> create?(%Sower.Orchestration.Garden{org_id: access_token.org_id}) do
      case Sower.Orchestration.register_new_garden(%{name: name, public_key: public_key}) do
        {:ok, garden, %{client_id: client_id}} ->
          conn
          |> put_status(:created)
          |> render(:register, garden: garden, client_id: client_id)

        {:error, reason} ->
          Logger.error(msg: "Garden registration failed", error: inspect(reason))

          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, error: "registration failed")
      end
    else
      conn |> put_status(:unauthorized) |> render(:error, error: "unauthorized")
    end
  end

  operation(:latest_seed,
    operation_id: "LatestGardenSeed",
    summary: "Find the latest seed for a garden's oldest matching subscription",
    parameters: [
      garden: [
        in: :path,
        required: true,
        description: "Garden SID or unambiguous name",
        type: :string
      ],
      name: [
        in: :query,
        required: true,
        description: "Seed name",
        type: :string
      ],
      seed_type: [
        in: :query,
        required: true,
        description: "Seed type",
        type: :string
      ]
    ],
    responses: %{
      ok: {"Latest matching seed", "application/json", SowerClient.Seed},
      no_content: "No matching subscription or seed",
      not_found:
        {"Garden not found", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      conflict:
        {"Garden name is ambiguous", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def latest_seed(conn, %{garden: identifier, name: name, seed_type: seed_type}) do
    token = conn.assigns.access_token

    if token |> can() |> read?(%Sower.Orchestration.Seed{org_id: token.org_id}) do
      case Sower.Orchestration.Garden.resolve(identifier) do
        {:ok, %Sower.Orchestration.Garden{org_id: org_id} = garden}
        when org_id == token.org_id ->
          case Sower.Orchestration.Subscription.find_for_garden_seed(garden, name, seed_type) do
            nil ->
              send_resp(conn, :no_content, "")

            subscription ->
              case Sower.Orchestration.Deployment.match_seed(subscription) do
                %Sower.Orchestration.Seed{org_id: org_id} = seed
                when org_id == token.org_id ->
                  conn
                  |> put_view(json: SowerWeb.Api.SeedJSON)
                  |> render(:show, seed: seed)

                _ ->
                  send_resp(conn, :no_content, "")
              end
          end

        {:ok, _garden} ->
          conn |> put_status(:not_found) |> render(:error, error: "garden_not_found")

        {:error, :garden_not_found} ->
          conn |> put_status(:not_found) |> render(:error, error: "garden_not_found")

        {:error, :ambiguous_garden} ->
          conn
          |> put_status(:conflict)
          |> render(:error, error: "garden name is ambiguous, use the sid")
      end
    else
      conn |> put_status(:unauthorized) |> render(:error, error: "unauthorized")
    end
  end
end
