defmodule SowerWeb.GardenChannelTest do
  use SowerWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

  alias Sower.Orchestration.{Deployment, DeploymentEvent, Garden}

  describe "connect/3" do
    test "authenticates via boruta token in x-auth-token header" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      %{boruta_token: boruta_token} = create_garden_with_oauth()

      {:ok, _socket} =
        connect(SowerWeb.GardenSocket, %{},
          connect_info: %{x_headers: [{"x-auth-token", "boruta:#{boruta_token}"}]}
        )
    end

    test "rejects non-boruta token" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      {:ok, access_token} =
        Sower.Accounts.AccessToken.create(%{
          "description" => "test",
          "user_id" => user.id,
          "org_id" => user.org_id,
          "permissions" => [%{"role" => "garden:register"}]
        })

      encoded_token = Base.encode64(access_token.token)

      capture_log(fn ->
        assert {:error, :unauthorized} =
                 connect(SowerWeb.GardenSocket, %{},
                   connect_info: %{x_headers: [{"x-auth-token", encoded_token}]}
                 )
      end)
    end

    test "rejects connection with no token" do
      capture_log(fn ->
        assert {:error, :unauthorized} =
                 connect(SowerWeb.GardenSocket, %{}, connect_info: %{x_headers: []})
      end)
    end
  end

  describe "join/3" do
    test "advertises pending deployments when joining the authenticated garden" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)
      %{garden: garden, boruta_token: token} = create_garden_with_oauth()

      {:ok, socket} =
        connect(SowerWeb.GardenSocket, %{},
          connect_info: %{x_headers: [{"x-auth-token", "boruta:#{token}"}]}
        )

      assert {:ok, %{pending_deployments: true}, _socket} =
               subscribe_and_join(
                 socket,
                 SowerWeb.GardenChannel,
                 "garden:#{garden.sid}",
                 %{}
               )
    end

    test "rejects join when garden does not exist" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      %{boruta_token: boruta_token} = create_garden_with_oauth()

      {:ok, socket} =
        connect(SowerWeb.GardenSocket, %{},
          connect_info: %{x_headers: [{"x-auth-token", "boruta:#{boruta_token}"}]}
        )

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 SowerWeb.GardenChannel,
                 "garden:nonexistent_sid",
                 %{}
               )
    end

    test "rejects join for a different garden than the authenticated one" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      %{boruta_token: boruta_token} = create_garden_with_oauth()
      other_garden = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})

      {:ok, socket} =
        connect(SowerWeb.GardenSocket, %{},
          connect_info: %{x_headers: [{"x-auth-token", "boruta:#{boruta_token}"}]}
        )

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 SowerWeb.GardenChannel,
                 "garden:#{other_garden.sid}",
                 %{}
               )
    end
  end

  describe "direct override capability" do
    setup do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)
      %{garden: garden, boruta_token: token} = create_garden_with_oauth()
      seed = seed_fixture()
      SowerWeb.Endpoint.subscribe("garden:presence")

      %{garden: garden, seed: seed, token: token}
    end

    test "permits an override only after the connection advertises support", %{
      garden: garden,
      seed: seed,
      token: token
    } do
      join_private(garden, token, %{"direct_override" => true})

      assert {:ok, _deployment} =
               Deployment.deploy_direct(garden, seed,
                 override: true,
                 action: "restart",
                 reason: "break glass",
                 actor_sid: "tok_2"
               )

      assert_push "deployment", %{seed_deployments: [%{action: "restart", override: true}]}
    end

    for {connection, params} <- [
          {"nonadvertising", %{}},
          {"legacy", %{"direct_override" => false}},
          {"truthy", %{"direct_override" => "true"}}
        ] do
      test "a #{connection} join cannot override but can deploy normally", %{
        garden: garden,
        seed: seed,
        token: token
      } do
        join_private(garden, token, unquote(Macro.escape(params)))

        assert {:error, :garden_upgrade_required} =
                 Deployment.deploy_direct(garden, seed,
                   override: true,
                   action: "restart",
                   reason: "break glass",
                   actor_sid: "tok_2"
                 )

        assert_no_dispatch()

        {:ok, garden} =
          Garden.update_garden(garden, %{
            policy: [%{name: "direct", actions: ["activate"], triggers: ["direct"]}]
          })

        assert {:ok, _deployment} = Deployment.deploy_direct(garden, seed)
        assert_push "deployment", %{seed_deployments: [%{action: "activate", override: false}]}
      end
    end

    test "rejects mixed capable and legacy private connections", %{
      garden: garden,
      seed: seed,
      token: token
    } do
      join_private(garden, token, %{"direct_override" => true})
      join_private(garden, token, %{})

      assert {:error, :garden_upgrade_required} =
               Deployment.deploy_direct(garden, seed,
                 override: true,
                 action: "restart",
                 reason: "break glass",
                 actor_sid: "tok_2"
               )

      assert_no_dispatch()
    end

    test "disconnect removes capability and a legacy reconnect cannot inherit it", %{
      garden: garden,
      seed: seed,
      token: token
    } do
      socket = join_private(garden, token, %{"direct_override" => true})
      garden_sid = garden.sid
      Process.unlink(socket.channel_pid)
      close(socket)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "presence_diff",
                       payload: %{leaves: %{^garden_sid => _}}
                     },
                     1_000

      assert {:error, :garden_upgrade_required} =
               Deployment.deploy_direct(garden, seed,
                 override: true,
                 action: "restart",
                 reason: "break glass",
                 actor_sid: "tok_2"
               )

      assert_no_dispatch()
      join_private(garden, token, %{})

      assert {:error, :garden_upgrade_required} =
               Deployment.deploy_direct(garden, seed,
                 override: true,
                 action: "restart",
                 reason: "break glass",
                 actor_sid: "tok_2"
               )

      assert_no_dispatch()
    end
  end

  describe "reconcile_deployments on join" do
    test "replays unresolved deployments and skips terminal ones" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      %{garden: garden, boruta_token: boruta_token} = create_garden_with_oauth()

      seed = seed_fixture(%{name: "replay-seed", seed_type: "nixos"})

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

      {:ok, socket} =
        connect(SowerWeb.GardenSocket, %{},
          connect_info: %{x_headers: [{"x-auth-token", "boruta:#{boruta_token}"}]}
        )

      {:ok, _reply, _socket} =
        subscribe_and_join(
          socket,
          SowerWeb.GardenChannel,
          "garden:#{garden.sid}",
          %{}
        )

      assert_push "deployment", payload
      assert payload.sid == unresolved.sid
      assert payload.skipped == false
      assert is_binary(payload.request_id)
      assert is_list(payload.seed_deployments)
    end
  end

  defp join_private(%Garden{} = garden, token, params) do
    {:ok, socket} =
      connect(SowerWeb.GardenSocket, %{},
        connect_info: %{x_headers: [{"x-auth-token", "boruta:#{token}"}]}
      )

    {:ok, _reply, socket} =
      subscribe_and_join(socket, SowerWeb.GardenChannel, "garden:#{garden.sid}", params)

    garden_sid = garden.sid

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{joins: %{^garden_sid => _}}
                   },
                   1_000

    socket
  end

  defp assert_no_dispatch do
    assert Sower.Repo.aggregate(Deployment, :count) == 0
    assert Sower.Repo.aggregate(DeploymentEvent, :count) == 0
    refute_push "deployment", _
  end
end
