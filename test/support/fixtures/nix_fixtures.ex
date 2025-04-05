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
        path: random_store_path()
      })
      |> Sower.Nix.create_store_path()

    store_path
  end

  def random_store_path(name \\ "apath-0.1") do
    digest =
      for _ <- 1..32, into: "", do: <<Enum.random(~c"0123456789abcdefghijklmnopqrstuvwxyz")>>

    "/nix/store/#{digest}-#{name}"
  end
end
