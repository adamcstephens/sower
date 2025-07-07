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
        local_sid: "some local_sid",
        sid: "some sid"
      })
      |> Sower.Orchestration.create_agent()

    agent
  end

  @doc """
  Generate a subscription.
  """
  def subscription_fixture(attrs \\ %{}) do
    {:ok, subscription} =
      attrs
      |> Enum.into(%{
        sid: "some sid"
      })
      |> Sower.Orchestration.create_subscription()

    subscription
  end
end
