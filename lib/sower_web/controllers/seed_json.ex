defmodule SowerWeb.SeedJSON do
  @doc """
  Renders a list of seeds.
  """
  def list(%{seeds: seeds}) do
    for(seed <- seeds, do: seed)
  end

  @doc """
  Renders a single item.
  """
  def show(%{seed: seed}) do
    seed
  end

  def show(%{store_path: store_path}) do
    store_path
  end

  def not_found(_) do
    %{error: "seed not found"}
  end

  def error(%{error: error}) do
    %{error: error}
  end

  def error(_) do
    %{error: "unknown"}
  end
end
