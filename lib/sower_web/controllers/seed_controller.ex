defmodule SowerWeb.SeedController do
  use SowerWeb, :controller

  action_fallback SowerWeb.FallbackController

  def new(conn, %{"name" => name, "type" => type, "out_path" => out_path}) do
    with {:ok, %Sower.Seed{} = seed} <- Sower.Seed.new(name, type, out_path) do
      conn
      |> put_status(:created)
      |> render(:show, seed: seed[0])
    end
  end

  def find_latest(conn, %{"name" => name, "type" => type}) do
    seed = Sower.Seed.latest!(name, type)
    render(conn, :show, seed: seed)
  end

  def list(conn, _) do
    seeds = Sower.Seed.read_all!()
    render(conn, :list, seeds: seeds)
  end
end
