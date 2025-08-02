defmodule SowerWeb.Api.SeedController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SowerClient.Schemas
  import Sower.Authorization

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  action_fallback SowerWeb.Api.FallbackController

  operation(:new,
    operation_id: "NewSeed",
    summary: "New Seed",
    parameters: [],
    request_body: {"Seed params", "application/json", Schemas.Seed},
    responses: %{
      created: {"Seed response", "application/json", Schemas.Seed},
      conflict:
        {"Seed conflict response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def new(
        %Plug.Conn{
          body_params: %Schemas.Seed{
            name: name,
            seed_type: seed_type,
            artifact: artifact
          }
        } = conn,
        _params
      ) do
    conn = Map.put(conn, :body_params, %{})

    if can(conn.assigns.access_token)
       |> create?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      case Sower.Seed.create(%{name: name, seed_type: seed_type, artifact: artifact}) do
        {:ok, %Sower.Seed{} = seed} ->
          conn
          |> put_status(:created)
          |> render(:show, seed: seed)

        {:error, %Ecto.Changeset{errors: errors}} ->
          Logger.error(error: "Failed to create seed", errors: errors)
          conn |> put_status(409) |> render(:error, error: "Failed to create seed")
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:latest,
    operation_id: "LatestSeed",
    summary: "Find latest Seed",
    parameters: [
      name: [
        description: "Seed name",
        type: :string,
        example: "host1"
      ],
      seed_type: [
        description: "Seed type",
        type: :string,
        example: "nixos"
      ]
    ],
    responses: %{
      ok: {"Seed response", "application/json", Schemas.Seed},
      not_found:
        {"Seed error response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def latest(conn, %{name: name, seed_type: seed_type}) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      case Sower.Seed.latest(name, seed_type) do
        nil ->
          conn |> put_status(404) |> render(:not_found)

        seed ->
          render(conn, :show, seed: seed)
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:get,
    operation_id: "GetSeed",
    summary: "Get Seed",
    parameters: [
      sid: [
        in: :path,
        description: "Seed SID",
        type: :string,
        example: "example4ser3adju75ddusbr"
      ]
    ],
    responses: [
      ok: {"Seed response", "application/json", Schemas.Seed},
      not_found:
        {"Seed error response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    ]
  )

  def get(conn, %{sid: sid}) do
    if conn.assigns.access_token
       |> can()
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      case Sower.Seed.get_sid(sid) do
        nil ->
          conn |> put_status(404) |> render(:error, error: "not found")

        seed ->
          render(conn, :show, seed: seed)
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  def get(conn, _) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      conn |> put_status(:not_found) |> render(:not_found)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:list,
    operation_id: "ListSeeds",
    summary: "List Seeds",
    parameters: [
      name: [
        description: "Seed name",
        type: :string,
        example: "host1"
      ],
      seed_type: [
        description: "Seed type, one of [#{Schemas.Seed.seed_types() |> Enum.join(", ")}]",
        type: :string,
        example: "nixos"
      ]
    ],
    responses: [
      ok: {"Seed response", "application/json", %Schema{type: :array, items: Schemas.Seed}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      not_found:
        {"Seed error response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    ]
  )

  def list(conn, %{name: name, seed_type: seed_type}) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      seed = Sower.Seed.get(name, seed_type)

      case seed do
        nil ->
          conn |> put_status(:not_found) |> render(:not_found)

        seed ->
          if can(conn.assigns.access_token) |> read?(seed) do
            render(conn, :list, seeds: [seed])
          else
            conn |> put_status(:unauthorized) |> render(:unauthorized)
          end
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  def list(conn, _) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      seeds = Sower.Seed.list()
      render(conn, :list, seeds: seeds)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end
end
