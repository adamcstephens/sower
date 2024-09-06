defmodule SowerWeb.SeedController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias SowerWeb.Schemas

  action_fallback SowerWeb.FallbackController

  operation :new,
    summary: "New Seed",
    parameters: [],
    request_body: {"Seed params", "application/json", Schemas.Seed.Request},
    responses: [
      ok: {"Seed response", "application/json", Schemas.Seed.Response}
    ]

  def new(conn, %{
        "name" => name,
        # TODO change seed-ci and rename this
        "seed_type" => seed_type,
        "store_path" => store_path
      }) do
    Logger.warning("Received legacy seed")

    with {:ok, %Sower.Seed{} = seed} <-
           Sower.Seed.submit(%{name: name, seed_type: seed_type, store_path: store_path}),
         Logger.debug(seed) do
      conn
      |> put_status(:created)
      |> render(:show, seed: seed)
    end
  end

  operation :find_latest,
    summary: "Get latest Seed",
    parameters: [],
    request_body: {"Seed params", "application/json", Schemas.Seed.Request},
    responses: [
      ok: {"Seed response", "application/json", Schemas.Seed.Response}
    ]

  def find_latest(conn, %{"name" => name, "type" => type}) do
    seed = Sower.Seed.latest(name, type)
    render(conn, :show, seed: seed)
  end

  operation :list,
    summary: "List Seeds",
    parameters: [],
    responses: [
      ok: {"Seed response", "application/json", Schemas.Seed.ListResponse}
    ]

  def list(conn, _) do
    seeds = Sower.Seed.list()
    render(conn, :list, seeds: seeds)
  end
end
