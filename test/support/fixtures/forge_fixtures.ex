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
        name: "some name",
        type: :forgejo,
        url: "some url"
      })
      |> Sower.Forge.create_connection()

    connection
  end
end
