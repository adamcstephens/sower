defmodule SowerWeb.GardenChannelTest do
  use SowerWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

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
    test "joins and assigns garden" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      assert socket.assigns.garden.id == garden.id
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
end
