defmodule SowerWeb.GardenChannelTest do
  use SowerWeb.ChannelCase, async: true

  describe "join/3" do
    test "joins with matching local_sid and assigns garden" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      assert socket.assigns.garden.id == garden.id
    end

    test "accepts legacy agent: topic prefix" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      {:ok, access_token} =
        Sower.Accounts.AccessToken.create(%{
          "description" => "test",
          "user_id" => user.id,
          "org_id" => user.org_id,
          "permissions" => [%{"role" => "garden:register"}]
        })

      garden =
        garden_fixture(%{
          sid: SowerClient.Sid.generate("grdn"),
          local_sid: SowerClient.Sid.generate("local")
        })

      encoded_token = Base.encode64(access_token.token)

      {:ok, socket} = connect(SowerWeb.GardenSocket, %{"token" => encoded_token})

      {:ok, _reply, socket} =
        subscribe_and_join(
          socket,
          SowerWeb.GardenChannel,
          "agent:#{garden.sid}",
          %{"local_sid" => garden.local_sid}
        )

      assert socket.assigns.garden.id == garden.id
    end

    test "rejects join when garden does not exist" do
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

      {:ok, socket} = connect(SowerWeb.GardenSocket, %{"token" => encoded_token})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 SowerWeb.GardenChannel,
                 "garden:nonexistent_sid",
                 %{"local_sid" => "some_local_sid"}
               )
    end

    test "rejects join when local_sid does not match" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      {:ok, access_token} =
        Sower.Accounts.AccessToken.create(%{
          "description" => "test",
          "user_id" => user.id,
          "org_id" => user.org_id,
          "permissions" => [%{"role" => "garden:register"}]
        })

      garden =
        garden_fixture(%{
          sid: SowerClient.Sid.generate("grdn"),
          local_sid: SowerClient.Sid.generate("local")
        })

      encoded_token = Base.encode64(access_token.token)

      {:ok, socket} = connect(SowerWeb.GardenSocket, %{"token" => encoded_token})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 SowerWeb.GardenChannel,
                 "garden:#{garden.sid}",
                 %{"local_sid" => "wrong_local_sid"}
               )
    end
  end

  describe "reconcile_deployments on join" do
    test "replays unresolved deployments and skips terminal ones" do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      {:ok, access_token} =
        Sower.Accounts.AccessToken.create(%{
          "description" => "test",
          "user_id" => user.id,
          "org_id" => user.org_id,
          "permissions" => [%{"role" => "garden:register"}]
        })

      garden =
        garden_fixture(%{
          sid: SowerClient.Sid.generate("grdn"),
          local_sid: SowerClient.Sid.generate("local")
        })

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

      encoded_token = Base.encode64(access_token.token)
      {:ok, socket} = connect(SowerWeb.GardenSocket, %{"token" => encoded_token})

      {:ok, _reply, _socket} =
        subscribe_and_join(
          socket,
          SowerWeb.GardenChannel,
          "garden:#{garden.sid}",
          %{"local_sid" => garden.local_sid}
        )

      assert_push "deployment", payload
      assert payload.sid == unresolved.sid
      assert payload.skipped == false
      assert is_binary(payload.request_id)
      assert is_list(payload.seed_deployments)
    end
  end
end
