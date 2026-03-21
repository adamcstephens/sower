defmodule SowerWeb.GardenChannelTest do
  use Sower.DataCase, async: true

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias Phoenix.Socket.Broadcast
  alias Sower.Accounts.AccessToken
  alias Sower.Orchestration
  alias SowerWeb.GardenChannel

  describe "join/3" do
    test "schedules replay when garden joins with matching local sid" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      garden = garden_fixture(%{sid: "garden_join_replay_1", local_sid: "garden_local_1"})

      socket = %Phoenix.Socket{
        assigns: %{
          conn_sid: "conn_1",
          access_token: %AccessToken{org_id: user.org_id}
        }
      }

      assert {:ok, %{conn_sid: "conn_1"}, joined_socket} =
               GardenChannel.join(
                 "garden:#{garden.sid}",
                 %{"local_sid" => "garden_local_1"},
                 socket
               )

      assert joined_socket.assigns.garden.id == garden.id
      assert_received :track_presence
      assert_received :replay_unresolved_deployments
    end

    test "accepts legacy agent: topic prefix for backward compatibility" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      garden = garden_fixture(%{sid: "garden_join_compat_1", local_sid: "garden_compat_local_1"})

      socket = %Phoenix.Socket{
        assigns: %{
          conn_sid: "conn_2",
          access_token: %AccessToken{org_id: user.org_id}
        }
      }

      assert {:ok, %{conn_sid: "conn_2"}, joined_socket} =
               GardenChannel.join(
                 "agent:#{garden.sid}",
                 %{"local_sid" => "garden_compat_local_1"},
                 socket
               )

      assert joined_socket.assigns.garden.id == garden.id
    end
  end

  describe "handle_info/2 replay_unresolved_deployments" do
    test "replays unresolved deployments and skips terminal ones" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      garden = garden_fixture(%{sid: "garden_replay_1"})
      seed = seed_fixture(%{name: "replay-seed-1", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      unresolved =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription],
          result: nil,
          deployed_at: nil
        })

      _terminal =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription],
          result: :success,
          state: :completed,
          deployed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      Phoenix.PubSub.subscribe(Sower.PubSub, "garden:#{garden.sid}")

      socket = %Phoenix.Socket{assigns: %{garden: garden}}

      assert {:noreply, ^socket} =
               GardenChannel.handle_info(:replay_unresolved_deployments, socket)

      assert_receive %Broadcast{
        topic: topic,
        event: "deployment",
        payload: payload
      }

      assert topic == "garden:#{garden.sid}"
      assert payload.sid == unresolved.sid
      assert payload.skipped == false
      assert is_binary(payload.request_id)
      assert is_list(payload.seed_deployments)

      assert Enum.map(Orchestration.list_unresolved_deployments_for_garden(garden), & &1.sid) == [
               unresolved.sid
             ]
    end
  end
end
