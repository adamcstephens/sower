defmodule SowerWeb.SeedController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SowerWeb.Schemas

  action_fallback SowerWeb.FallbackController

  operation :new,
    operation_id: "NewSeed",
    summary: "New Seed",
    parameters: [],
    request_body: {"Seed params", "application/json", Schemas.Seed},
    responses: [
      ok: {"Seed response", "application/json", Schemas.Seed}
    ]

  def new(conn, %{
        "name" => name,
        "seed_type" => seed_type
      }) do
    with {:ok, %Sower.Seed{} = seed} <-
           Sower.Seed.new(%{name: name, seed_type: seed_type}),
         Logger.debug(seed) do
      conn
      |> put_status(:created)
      |> render(:show, seed: seed)
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
      ok: {"Seed response", "application/json", Schemas.StorePath}
    ]

  def new_store_path(conn, %{"id" => id, "path" => path}) do
    with {:ok, %Sower.StorePath{} = seed} <-
           Sower.Seed.submit(%{id: id, path: path}),
         Logger.debug(seed) do
      conn
      |> put_status(:created)
      |> render(:show, seed: seed)
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
    responses: [
      ok: {"Seed response", "application/json", Schemas.StorePath}
    ]

  def latest(conn, params) do
    seed = Sower.Seed.latest_store_path_by_id(params["id"])
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
      ok: {"Seed response", "application/json", %Schema{type: :array, items: Schemas.Seed}}
    ]

  def get(conn, params) do
    seed = Sower.Seed.get_by_id!(params["id"])
    render(conn, :show, seed: seed)
  end

  operation :list,
    operation_id: "ListSeeds",
    summary: "List Seeds",
    parameters: [],
    responses: [
      ok: {"Seed response", "application/json", %Schema{type: :array, items: Schemas.Seed}}
    ]

  def list(conn, _) do
    seeds = Sower.Seed.list()
    render(conn, :list, seeds: seeds)
  end
end
