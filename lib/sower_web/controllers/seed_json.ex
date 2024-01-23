defmodule SowerWeb.SeedJSON do
  @doc """
  Renders a list of seeds.
  """
  def index(%{seeds: seeds}) do
    %{data: for(seed <- seeds, do: data(seed))}
  end

  @doc """
  Renders a single seed.
  """
  def show(%{seed: seed}) do
    %{data: data(seed)}
  end

  defp data(%Sower.Seed.Instance{} = seed) do
    %{
      id: seed.id
    }
  end
end
