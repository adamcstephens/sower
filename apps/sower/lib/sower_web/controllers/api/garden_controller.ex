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

  operation(:rekey,
    operation_id: "RekeyGarden",
    summary: "Re-key a garden's OAuth client",
    parameters: [
      sid: [
        in: :path,
        type: :string,
        description: "Garden SID",
        required: true
      ]
    ],
    request_body: {"Garden rekey params", "application/json", SowerClient.GardenRekey},
    responses: %{
      ok:
        {"Garden rekey response", "application/json",
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
      not_found:
        {"Not found", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unprocessable_entity:
        {"Rekey error", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def rekey(
        %Plug.Conn{
          body_params: %SowerClient.GardenRekey{
            public_key: public_key
          }
        } = conn,
        %{sid: sid}
      ) do
    access_token = conn.assigns.access_token

    if can(access_token)
       |> create?(%Sower.Orchestration.Garden{org_id: access_token.org_id}) do
      case Sower.Orchestration.Garden.get_garden_sid(sid) do
        nil ->
          conn
          |> put_status(:not_found)
          |> render(:error, error: "garden not found")

        garden ->
          case Sower.Orchestration.Garden.rekey_garden(garden, public_key) do
            {:ok, garden, %{client_id: client_id}} ->
              conn
              |> put_status(:ok)
              |> render(:register, garden: garden, client_id: client_id)

            {:error, reason} ->
              Logger.error(msg: "Garden rekey failed", error: inspect(reason))

              conn
              |> put_status(:unprocessable_entity)
              |> render(:error, error: "rekey failed")
          end
      end
    else
      conn |> put_status(:unauthorized) |> render(:error, error: "unauthorized")
    end
  end
end
