defmodule SowerWeb.SeedJSON do
  @doc """
  Renders a list of seeds.
  """
  def list(%{seeds: seeds}) do
    for(seed <- seeds, do: seed)
  end

  @doc """
  Renders a single seed.
  """
  def show(%{seed: seed}) do
    seed
  end

  def not_found(_) do
    %{error: "seed not found"}
  end
end
