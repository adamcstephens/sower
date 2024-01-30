defmodule SowerWeb.SeedController do
  use SowerWeb, :controller

  action_fallback SowerWeb.FallbackController

  def new(conn, seed_params) do
    with {:ok, %Sower.Seed.Instance{} = seed} <- Sower.Seed.create_or_insert_seed(seed_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/seeds/#{seed}")
      |> render(:show, seed: seed)
    end
  end

  def list(conn, _) do
    seeds = Sower.Seed.list_seeds()
    render(conn, :list, seeds: seeds)
  end

  def show(conn, %{"id" => id}) do
    seed = Sower.Seed.get_seed!(id)
    render(conn, :show, seed: seed)
  end
end
