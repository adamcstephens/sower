defmodule SowerWeb.SeedController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SowerWeb.Schemas
  import Sower.Authorization
  require OpenTelemetry.Tracer, as: Tracer

  plug(OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true)

  action_fallback(SowerWeb.FallbackController)

  operation(:new,
    operation_id: "NewSeed",
    summary: "New Seed",
    parameters: [],
    request_body: {"Seed params", "application/json", Schemas.Seed},
    responses: %{
      created: {"Seed response", "application/json", Schemas.Seed},
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
       |> create?(%Sower.Seed{org_id: conn.assigns.access_token.user.org_id}) do
      with {:ok, %Sower.Seed{} = seed} <-
             Sower.Seed.create(%{name: name, seed_type: seed_type}),
           Logger.debug(seed) do
        conn
        |> put_status(:created)
        |> render(:show, seed: seed)
      else
        {:error, %Ecto.Changeset{errors: errors}} ->
          Logger.error(errors)
          conn |> put_status(400) |> render(:error, error: "unauthorized")
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:new_store_path,
    operation_id: "NewSeedStorePath",
    summary: "New Seed Store Path",
    parameters: [
      id: [
        in: :path,
        description: "Seed ID",
        type: :string,
        example: "1234-5678-1234-5678"
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
        %{id: id}
      ) do
    if can(conn.assigns.access_token)
       |> update?(%Sower.Seed{org_id: conn.assigns.access_token.user.org_id}) do
      with {:ok, %Sower.StorePath{} = store_path} <-
             Sower.Seed.submit(id, path),
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
      id: [
        in: :path,
        description: "Seed ID",
        type: :string,
        example: "1234-5678-1234-5678"
      ]
    ],
    responses: %{
      ok: {"Seed response", "application/json", Schemas.StorePath},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def latest(conn, %{id: id}) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.user.org_id}) do
      seed = Sower.Seed.latest_store_path_by_id(id)
      render(conn, :show, seed: seed)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:get,
    operation_id: "GetSeed",
    summary: "Get Seed",
    parameters: [
      id: [
        in: :path,
        description: "Seed ID",
        type: :string,
        example: "1234-5678-1234-5678"
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

  def get(conn, %{id: id}) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.user.org_id}) do
      seed = Sower.Seed.get_by_id!(id)
      render(conn, :show, seed: seed)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  def get(conn, _) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.user.org_id}) do
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
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.user.org_id}) do
      Tracer.with_span "list single seed" do
        Tracer.set_attributes(name: name, seed_type: seed_type)

        seed = Sower.Seed.get(name, seed_type)

        case seed do
          nil ->
            Tracer.set_status(:error, "not found")
            conn |> put_status(:not_found) |> render(:not_found)

          seed ->
            if can(conn.assigns.access_token) |> read?(seed) do
              render(conn, :list, seeds: [seed])
            else
              Tracer.set_status(:error, "unauthorized")
              conn |> put_status(:unauthorized) |> render(:unauthorized)
            end
        end
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  def list(conn, _) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Seed{org_id: conn.assigns.access_token.user.org_id}) do
      seeds = Sower.Seed.list()
      render(conn, :list, seeds: seeds)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end
end
