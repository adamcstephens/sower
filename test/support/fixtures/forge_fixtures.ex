defmodule Sower.ForgeFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Forge` context.
  """

  @doc """
  Generate a repository.
  """
  def repository_fixture(attrs \\ %{}) do
    {:ok, repository} =
      attrs
      |> Enum.into(%{
        url: "some url"
      })
      |> Sower.Forge.create_repository()

    repository
  end
end
