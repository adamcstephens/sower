defmodule Sower.NixFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Nix` context.
  """

  @doc """
  Generate a cache.
  """
  def cache_fixture(attrs \\ %{}) do
    {:ok, cache} =
      attrs
      |> Enum.into(%{
        public_key: "some public_key",
        url: "some url"
      })
      |> Sower.Nix.create_cache()

    cache
  end

  @doc """
  Generate a store_path.
  """
  def store_path_fixture(attrs \\ %{}) do
    {:ok, store_path} =
      attrs
      |> Enum.into(%{
        path: "some path"
      })
      |> Sower.Nix.create_store_path()

    store_path
  end
end
