defmodule Sower.SCMFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.SCM` context.
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
      |> Sower.SCM.create_hook()

    hook
  end
end
