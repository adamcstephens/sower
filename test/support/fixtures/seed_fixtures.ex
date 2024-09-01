defmodule Sower.SeedFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Seed` context.
  """

  def unique_seed_name, do: "seed#{System.unique_integer()}"

  def random_store_path do
    "/nix/store/#{:crypto.strong_rand_bytes(32) |> Base.encode16() |> String.slice(0..31) |> String.downcase()}-something"
  end

  def valid_seed_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_seed_name(),
      seed_type: "nixos",
      store_path: random_store_path()
    })
  end

  def seed_fixture(attrs \\ %{}) do
    {:ok, seed} =
      attrs
      |> valid_seed_attributes()
      |> Sower.Seed.submit()

    seed
  end
end
