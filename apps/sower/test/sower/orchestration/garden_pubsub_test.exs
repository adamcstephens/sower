defmodule Sower.Orchestration.GardenPubSubTest do
  use Sower.DataCase, async: true

  alias Sower.Orchestration.GardenPubSub

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  test "broadcast_garden_change/2 publishes per-garden view topic", %{organization: org} do
    garden = garden_fixture(%{org_id: org.org_id})

    Phoenix.PubSub.subscribe(Sower.PubSub, "garden:view:#{garden.sid}")

    assert {:ok, _garden} = GardenPubSub.broadcast_garden_change(garden, :updated)

    garden_sid = garden.sid
    assert_receive {:garden, :updated, %{sid: ^garden_sid}}
  end

  test "broadcast_seed_generations_change/2 publishes per-garden view topic", %{
    organization: org
  } do
    garden = garden_fixture(%{org_id: org.org_id})

    Phoenix.PubSub.subscribe(Sower.PubSub, "garden:view:#{garden.sid}")

    assert {:ok, _garden} = GardenPubSub.broadcast_seed_generations_change(garden, :updated)

    garden_sid = garden.sid
    assert_receive {:garden_seed_generations, :updated, %{sid: ^garden_sid}}
  end
end
