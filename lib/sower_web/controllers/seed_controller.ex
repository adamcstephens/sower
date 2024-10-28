defmodule SowerWeb.SeedController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SowerWeb.Schemas

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  action_fallback SowerWeb.FallbackController

  operation :new,
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

  def new(
        %Plug.Conn{
          body_params: %Schemas.Seed{
            name: name,
            seed_type: seed_type
          }
        } = conn,
        _params
      ) do
    with {:ok, %Sower.Seed{} = seed} <-
           Sower.Seed.create(%{name: name, seed_type: seed_type}),
         Logger.debug(seed) do
      conn
      |> put_status(:created)
      |> render(:show, seed: seed)
    else
      {:error, %Ecto.Changeset{errors: errors}} ->
        Logger.error(errors)
        conn |> put_status(:unprocessable_content)
    end
  end

  operation :new_store_path,
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

  def new_store_path(
        %Plug.Conn{
          body_params: %Schemas.StorePath{
            path: path
          }
        } = conn,
        %{id: id}
      ) do
    with {:ok, %Sower.StorePath{} = store_path} <-
           Sower.Seed.submit(id, path),
         Logger.debug(store_path) do
      conn
      |> put_status(:created)
      |> render(:show, store_path: store_path)
    end
  end

  operation :latest,
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

  def latest(conn, %{id: id}) do
    seed = Sower.Seed.latest_store_path_by_id(id)
    render(conn, :show, seed: seed)
  end

  operation :get,
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

  def get(conn, %{id: id}) do
    seed = Sower.Seed.get_by_id!(id)
    render(conn, :show, seed: seed)
  end

  def get(conn, _) do
    conn |> put_status(:not_found) |> render(:not_found)
  end

  operation :list,
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

  def list(conn, %{name: name, seed_type: seed_type}) do
    seed = Sower.Seed.get(name, seed_type)

    case seed do
      nil ->
        conn |> put_status(:not_found) |> render(:not_found)

      seed ->
        render(conn, :list, seeds: [seed])
    end
  end

  def list(conn, _) do
    seeds = Sower.Seed.list()
    render(conn, :list, seeds: seeds)
  end
end
