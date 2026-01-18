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
        name: SowerClient.Sid.generate("agent"),
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
      |> Enum.into(%{})
      |> Sower.Orchestration.create_subscription()

    subscription
  end

  @doc """
  Generate a deployment.
  """
  def deployment_fixture(attrs \\ %{}) do
    {:ok, deployment} =
      attrs
      |> Enum.into(%{seeds: [], subscriptions: []})
      |> Sower.Orchestration.create_deployment()

    deployment
  end

  @doc """
  Generate a nix_profile.
  """
  def nix_profile_fixture(attrs \\ %{}) do
    profile_path = Map.get(attrs, :profile_path, "/nix/var/nix/profiles/system")

    Sower.Orchestration.NixProfile.find_or_create!(profile_path)
  end

  @doc """
  Generate an agent_seed_generation.
  """
  def agent_seed_generation_fixture(attrs \\ %{}) do
    alias Sower.Orchestration.AgentSeedGeneration

    attrs =
      attrs
      |> Enum.into(%{
        org_id: Sower.Repo.get_org_id(),
        generation_number: 1,
        is_current: true,
        created_at_generation: DateTime.utc_now()
      })

    %AgentSeedGeneration{}
    |> AgentSeedGeneration.changeset(attrs)
    |> Sower.Repo.insert!()
  end
end
