defmodule SowerWeb.Api.Nix.CacheJSON do
  @doc """
  Renders a list of seeds.
  """
  def list(%{caches: caches}) do
    for(cache <- caches, do: cache)
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

  def unauthorized(_) do
    %{error: "unauthorized"}
  end
end
