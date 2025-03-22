defmodule SowerWeb.Api.SeedController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SowerWeb.Schemas
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
            seed_type: seed_type
          }
        } = conn,
        _params
      ) do
    if can(conn.assigns.access_token)
       |> create?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      with {:ok, %Sower.Seed{} = seed} <-
             Sower.Seed.create(%{name: name, seed_type: seed_type}),
           Logger.debug(seed) do
        conn
        |> put_status(:created)
        |> render(:show, seed: seed)
      else
        {:error, %Ecto.Changeset{errors: errors}} ->
          Logger.error(errors)
          conn |> put_status(409) |> render(:error, error: "seed already exists")
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:new_store_path,
    operation_id: "NewSeedStorePath",
    summary: "New Seed Store Path",
    parameters: [
      sid: [
        in: :path,
        description: "Seed SID",
        type: :string,
        example: "example4ser3adju75ddusbr"
      ]
    ],
    request_body: {"Seed params", "application/json", Schemas.StorePath},
    responses: [
      created: {"Seed response", "application/json", Schemas.StorePath},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    ]
  )

  def new_store_path(
        %Plug.Conn{
          body_params: %Schemas.StorePath{
            path: path
          }
        } = conn,
        %{sid: sid}
      ) do
    if can(conn.assigns.access_token)
       |> update?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      with {:ok, %Sower.Nix.StorePath{} = store_path} <-
             Sower.Seed.submit(sid, path),
           Logger.debug(store_path) do
        conn
        |> put_status(:created)
        |> render(:show, store_path: store_path)
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:latest,
    operation_id: "LatestStorePathBySeed",
    summary: "Get latest Store Path for a Seed",
    parameters: [
      sid: [
        in: :path,
        description: "Seed SID",
        type: :string,
        example: "example4ser3adju75ddusbr"
      ]
    ],
    responses: %{
      ok: {"Seed response", "application/json", Schemas.StorePath},
      not_found:
        {"Store Path error response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def latest(conn, %{sid: sid}) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      case Sower.Seed.latest_store_path_by_sid(sid) do
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
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.org_id}) do
      seed = Sower.Seed.get_sid!(sid)
      render(conn, :show, seed: seed)
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
        description: "Seed type (nixos, home-manager, etc.)",
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
