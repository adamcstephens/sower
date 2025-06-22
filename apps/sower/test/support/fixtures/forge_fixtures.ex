defmodule Sower.ForgeFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Forge` context.
  """

  @doc """
  Generate a connection.
  """
  def connection_fixture(attrs \\ %{}) do
    {:ok, connection} =
      attrs
      |> Enum.into(%{
        client_id: "some client_id",
        client_secret: "some client_secret",
        name: Faker.Company.bullshit(),
        type: :forgejo,
        url: "some url"
      })
      |> Sower.Forge.create_connection()

    connection
  end

  @doc """
  Generate a repository.
  """
  def repository_fixture(attrs \\ %{}) do
    {:ok, repository} =
      attrs
      |> Enum.into(%{
        owner: "some owner",
        repo: "some repo",
        url: "some url",
        webhook_id: "some webhook_id",
        forge_id: connection_fixture().id
      })
      |> Sower.Forge.create_repository()

    repository
  end
end
