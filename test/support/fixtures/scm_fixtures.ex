defmodule Sower.ForgeFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Forge` context.
  """

  @doc """
  Generate a hook.
  """
  def hook_fixture(attrs \\ %{}) do
    {:ok, hook} =
      attrs
      |> Enum.into(%{
        request: %{}
      })
      |> Sower.Forge.create_hook()

    hook
  end
end
