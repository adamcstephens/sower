defmodule SowerWeb.Api.ExecutionController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs
  import Sower.Authorization
  alias OpenApiSpex.Schema
  alias Sower.Orchestration.Executions
  alias Sower.Orchestration.Execution
  alias SowerClient.Orchestration.Execution.{History, Info, Request}

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  @error %Schema{type: :object, properties: %{error: %Schema{type: :string}}}
  @sid [sid: [in: :path, type: :string, required: true]]

  operation(:create,
    operation_id: "NewExecution",
    summary: "Queue a stock-image execution",
    request_body: {"Execution", "application/json", Request},
    responses: [
      accepted: {"Queued execution", "application/json", Info},
      forbidden: {"Forbidden", "application/json", @error}
    ]
  )

  def create(%Plug.Conn{body_params: %Request{} = request} = conn, _params) do
    token = conn.assigns.access_token

    if token |> can() |> create?(%Execution{org_id: token.org_id}) do
      case Executions.submit(request, token) do
        {:ok, execution} ->
          conn |> put_status(:accepted) |> json(Executions.info(execution))

        {:error, _reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid execution"})
      end
    else
      forbidden(conn)
    end
  end

  operation(:index,
    operation_id: "ListExecutions",
    summary: "List the latest 100 org executions",
    responses: [
      ok: {"Executions", "application/json", %Schema{type: :array, items: Info}},
      forbidden: {"Forbidden", "application/json", @error}
    ]
  )

  def index(conn, _params) do
    if readable?(conn) do
      json(conn, Enum.map(Executions.list(), &Executions.info/1))
    else
      forbidden(conn)
    end
  end

  operation(:get,
    operation_id: "GetExecution",
    summary: "Inspect an execution",
    parameters: @sid,
    responses: [
      ok: {"Execution", "application/json", Info},
      not_found: {"Not found", "application/json", @error},
      forbidden: {"Forbidden", "application/json", @error}
    ]
  )

  def get(conn, %{sid: sid}) do
    if readable?(conn) do
      case Executions.get(sid) do
        nil -> missing(conn)
        execution -> json(conn, Executions.info(execution))
      end
    else
      forbidden(conn)
    end
  end

  operation(:logs,
    operation_id: "GetExecutionLogs",
    summary: "Read ordered events after a cursor; poll to follow",
    parameters: @sid ++ [after: [in: :query, schema: %Schema{type: :integer, minimum: 0}]],
    responses: [
      ok: {"Execution history", "application/json", History},
      not_found: {"Not found", "application/json", @error},
      forbidden: {"Forbidden", "application/json", @error}
    ]
  )

  def logs(conn, %{sid: sid} = params) do
    if readable?(conn) do
      case Executions.get(sid) do
        nil -> missing(conn)
        execution -> json(conn, Executions.history(execution, Map.get(params, :after, 0)))
      end
    else
      forbidden(conn)
    end
  end

  operation(:cancel,
    operation_id: "CancelExecution",
    summary: "Request cancellation; teardown is asynchronous",
    parameters: @sid,
    responses: [
      ok: {"Execution", "application/json", Info},
      not_found: {"Not found", "application/json", @error},
      forbidden: {"Forbidden", "application/json", @error}
    ]
  )

  def cancel(conn, %{sid: sid}) do
    token = conn.assigns.access_token

    if token |> can() |> update?(%Execution{org_id: token.org_id}) do
      case Executions.cancel(sid) do
        {:ok, execution} -> json(conn, Executions.info(execution))
        {:error, :not_found} -> missing(conn)
      end
    else
      forbidden(conn)
    end
  end

  defp readable?(conn) do
    token = conn.assigns.access_token
    token |> can() |> read?(%Execution{org_id: token.org_id})
  end

  defp forbidden(conn), do: conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  defp missing(conn), do: conn |> put_status(:not_found) |> json(%{error: "not found"})
end
