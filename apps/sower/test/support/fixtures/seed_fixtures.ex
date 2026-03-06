defmodule Sower.SeedFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Orchestration.Seed` context.
  """

  def unique_seed_name, do: "seed#{System.unique_integer()}"

  def random_nix_artifact do
    "/nix/store/#{:crypto.strong_rand_bytes(32) |> Base.encode16() |> String.slice(0..31) |> String.downcase()}-something"
  end

  def valid_seed_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_seed_name(),
      seed_type: "nixos",
      artifact: random_nix_artifact()
    })
  end

  def seed_fixture(attrs \\ %{}) do
    {:ok, seed} =
      attrs
      |> valid_seed_attributes()
      |> Sower.Orchestration.Seed.create()

    seed
  end

  def artifact_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{path: random_nix_artifact()})
  end
end
