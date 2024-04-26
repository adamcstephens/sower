defmodule SowerWeb.SeedController do
  use SowerWeb, :controller

  require Logger

  action_fallback SowerWeb.FallbackController

  def new(conn, %{
        "name" => name,
        "type" => type,
        "out_path" => out_path,
        "branch" => branch,
        "repo_url" => repo_url
      }) do
    Logger.debug("Received seed.")

    with {:ok, %Sower.Seed{} = seed} <- Sower.Seed.new(name, type, out_path, branch, repo_url) do
      conn
      |> put_status(:created)
      |> render(:show, seed: seed)
    end
  end

  def new(conn, %{
        "name" => name,
        "type" => type,
        "out_path" => out_path
      }) do
    Logger.warning("Received legacy seed")

    with {:ok, %Sower.Seed{} = seed} <- Sower.Seed.new_legacy(name, type, out_path),
         Logger.debug(seed) do
      conn
      |> put_status(:created)
      |> render(:show, seed: seed)
    end
  end

  def find_latest(conn, %{"name" => name, "type" => type}) do
    with {:ok, seed} <- Sower.Seed.latest(name, type) do
      render(conn, :show, seed: seed)
    end
  end

  def list(conn, _) do
    seeds = Sower.Seed.read_all!()
    render(conn, :list, seeds: seeds)
  end
end
