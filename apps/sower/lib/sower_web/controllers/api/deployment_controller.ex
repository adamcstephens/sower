defmodule SowerWeb.Api.DeploymentController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias Sower.Orchestration.{Deployment, Garden, Seed}
  alias SowerClient.Orchestration.DeploymentInfo
  alias SowerClient.Orchestration.DirectDeployment

  import Sower.Authorization

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  action_fallback SowerWeb.Api.FallbackController

  @error_schema %Schema{type: :object, properties: %{error: %Schema{type: :string}}}

  operation(:create,
    operation_id: "NewDeployment",
    summary: "Deploy a seed directly at a garden",
    request_body: {"Direct deployment params", "application/json", DirectDeployment},
    responses: %{
      created: {"Deployment response", "application/json", DeploymentInfo},
      conflict:
        {"Ambiguous garden name or garden upgrade required", "application/json", @error_schema},
      forbidden: {"Denied by policy", "application/json", @error_schema},
      not_found: {"Garden or seed not found", "application/json", @error_schema},
      unprocessable_entity: {"Invalid request", "application/json", @error_schema},
      unauthorized: {"Unauthorized", "application/json", @error_schema}
    }
  )

  def create(%Plug.Conn{body_params: %DirectDeployment{} = params} = conn, _params) do
    token = conn.assigns.access_token
    conn = Map.put(conn, :body_params, %{})
    deployment = %Deployment{org_id: token.org_id}

    cond do
      not (token |> can() |> create?(deployment)) ->
        conn |> put_status(401) |> render(:error, error: "unauthorized")

      params.override and not (token |> can() |> override?(deployment)) ->
        conn |> put_status(401) |> render(:error, error: "unauthorized")

      true ->
        deploy(conn, params, token)
    end
  end

  defp deploy(conn, %DirectDeployment{} = params, token) do
    with {:ok, garden} <- Garden.resolve(params.garden),
         {:ok, seed} <- fetch_seed(params.seed),
         {:ok, dispatched} <-
           Deployment.deploy_direct(garden, seed,
             action: params.action,
             force: params.force,
             override: params.override,
             reason: params.reason,
             actor_sid: token.sid
           ) do
      conn
      |> put_status(:created)
      |> render(:show,
        deployment: Deployment.get_deployment_detail(dispatched.sid),
        skipped: dispatched.skipped
      )
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  operation(:get,
    operation_id: "GetDeployment",
    summary: "Get a deployment",
    parameters: [
      sid: [
        in: :path,
        description: "Deployment SID",
        type: :string,
        example: "dply_example4ser3adju75d"
      ]
    ],
    responses: %{
      ok: {"Deployment response", "application/json", DeploymentInfo},
      not_found: {"Deployment not found", "application/json", @error_schema},
      unauthorized: {"Unauthorized", "application/json", @error_schema}
    }
  )

  def get(conn, %{sid: sid}) do
    token = conn.assigns.access_token

    if token |> can() |> read?(%Deployment{org_id: token.org_id}) do
      case Deployment.get_deployment_detail(sid) do
        nil -> conn |> put_status(404) |> render(:error, error: "not found")
        deployment -> render(conn, :show, deployment: deployment, skipped: false)
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  defp fetch_seed(sid) do
    case Seed.get_sid(sid) do
      nil -> {:error, :seed_not_found}
      seed -> {:ok, seed}
    end
  end

  defp render_error(conn, :ambiguous_garden) do
    conn |> put_status(409) |> render(:error, error: "garden name is ambiguous, use the sid")
  end

  defp render_error(conn, :garden_upgrade_required) do
    conn
    |> put_status(409)
    |> render(:error,
      error:
        "garden upgrade required for direct override; upgrade and reconnect all garden connections"
    )
  end

  defp render_error(conn, reason) when reason in [:garden_not_found, :seed_not_found] do
    conn |> put_status(404) |> render(:error, error: to_string(reason))
  end

  defp render_error(conn, reason)
       when reason in [:policy_denied, :confirmation_required] do
    conn |> put_status(403) |> render(:error, error: to_string(reason))
  end

  defp render_error(conn, reason)
       when reason in [:override_action_required, :override_reason_required, :unsupported_action] do
    conn |> put_status(422) |> render(:error, error: to_string(reason))
  end

  defp render_error(conn, reason) do
    Logger.error(msg: "Direct deployment failed", reason: inspect(reason))
    conn |> put_status(422) |> render(:error, error: "deployment failed")
  end
end
