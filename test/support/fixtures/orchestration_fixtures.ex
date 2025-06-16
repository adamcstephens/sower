defmodule Sower.OrchestrationFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Orchestration` context.
  """

  @doc """
  Generate a agent.
  """
  def agent_fixture(attrs \\ %{}) do
    {:ok, agent} =
      attrs
      |> Enum.into(%{
        remote_sid: "some remote_sid",
        sid: "some sid"
      })
      |> Sower.Orchestration.create_agent()

    agent
  end
end
