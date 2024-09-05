defmodule SowerWeb.SeedController do
  use SowerWeb, :controller

  require Logger

  action_fallback SowerWeb.FallbackController

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

  def find_latest(conn, %{"name" => name, "type" => type}) do
    seed = Sower.Seed.latest(name, type)
    render(conn, :show, seed: seed)
  end

  def list(conn, _) do
    seeds = Sower.Seed.list()
    render(conn, :list, seeds: seeds)
  end
end
