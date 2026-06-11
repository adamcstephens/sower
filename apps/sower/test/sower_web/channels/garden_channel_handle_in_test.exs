defmodule SowerWeb.GardenChannelHandleInTest do
  use SowerWeb.ChannelCase, async: true

  describe "ping" do
    test "replies with pong" do
      %{socket: socket} = connect_and_join_garden()

      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, :pong, 1_000
    end
  end

  describe "deployment:request" do
    test "returns request_id for valid deployment request" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "deploy-req-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      ref =
        push(socket, "deployment:request", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "subscription_sids" => [subscription.sid]
        })

      assert_reply ref, :ok, %{request_id: request_id}, 1_000
      assert is_binary(request_id)

      # Wait for the async deployment task to complete before test exits
      assert_push "deployment", _payload, 5000
    end

    @tag :capture_log
    test "returns error for unknown subscription" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:request", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "subscription_sids" => ["nonexistent_sid"]
        })

      assert_reply ref, :error, :subscription_not_found, 1_000
    end
  end

  describe "deployment:status" do
    test "updates deployment state to acknowledged" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "deploy-status-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:status", %{
          "deployment_sid" => deployment.sid,
          "status" => "acknowledged"
        })

      assert_reply ref, :ok, reply, 1_000
      assert reply.state == :acknowledged
    end

    @tag :capture_log
    test "returns error for unknown deployment" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:status", %{
          "deployment_sid" => "nonexistent_sid",
          "status" => "acknowledged"
        })

      assert_reply ref, :error, :deployment_not_found, 1_000
    end
  end

  describe "deployment:result" do
    test "records deployment result and marks completed" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "deploy-result-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:result", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "deployment_sid" => deployment.sid,
          "result" => "success",
          "deployed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert_reply ref, :ok, reply, 1_000
      assert reply.state == :completed
      assert reply.result == :success
    end

    @tag :capture_log
    test "returns error for unknown deployment" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:result", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "deployment_sid" => "nonexistent_sid",
          "result" => "success"
        })

      assert_reply ref, :error, :deployment_not_found, 1_000
    end
  end

  describe "deployment:seed_status" do
    test "updates seed deployment state" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "seed-status-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:seed_status", %{
          "deployment_sid" => deployment.sid,
          "seed_sid" => seed.sid,
          "status" => "downloading"
        })

      assert_reply ref, :ok, %{}, 1_000
    end

    @tag :capture_log
    test "returns error for unknown deployment" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:seed_status", %{
          "deployment_sid" => "nonexistent_sid",
          "seed_sid" => "nonexistent_seed",
          "status" => "downloading"
        })

      assert_reply ref, :error, :deployment_not_found, 1_000
    end

    @tag :capture_log
    test "returns error for seed not in deployment" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "seed-status-miss", seed_type: "nixos"})
      other_seed = seed_fixture(%{name: "seed-status-other", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:seed_status", %{
          "deployment_sid" => deployment.sid,
          "seed_sid" => other_seed.sid,
          "status" => "downloading"
        })

      assert_reply ref, :error, :seed_not_in_deployment, 1_000
    end
  end

  describe "deployment:seed_result" do
    test "records seed deployment result and updates DB" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "seed-result-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:seed_result", %{
          "deployment_sid" => deployment.sid,
          "seed_sid" => seed.sid,
          "result" => "success",
          "log" => "deployment completed successfully"
        })

      assert_reply ref, :ok, %{}, 1_000

      [seed_deployment] =
        Sower.Repo.preload(deployment, :seed_deployments, force: true).seed_deployments

      assert seed_deployment.result == :success
      assert seed_deployment.log == "deployment completed successfully"
    end

    test "appends log without setting result (log-only update)" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "seed-result-logonly", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:seed_result", %{
          "deployment_sid" => deployment.sid,
          "seed_sid" => seed.sid,
          "log" => "partial output"
        })

      assert_reply ref, :ok, %{}, 1_000

      [seed_deployment] =
        Sower.Repo.preload(deployment, :seed_deployments, force: true).seed_deployments

      assert seed_deployment.result == nil
      assert seed_deployment.log == "partial output"
    end

    @tag :capture_log
    test "returns error for unknown deployment" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:seed_result", %{
          "deployment_sid" => "nonexistent_sid",
          "seed_sid" => "nonexistent_seed",
          "result" => "success"
        })

      assert_reply ref, :error, :deployment_not_found, 1_000
    end
  end

  describe "subscriptions:sync" do
    test "creates new subscriptions and returns them" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "subscriptions:sync", %{
          "subscriptions" => [
            %{"name" => "sync-host-1", "seed_name" => "sync-host-1", "seed_type" => "nixos"},
            %{"name" => "sync-host-2", "seed_name" => "sync-host-2", "seed_type" => "nixos"}
          ]
        })

      assert_reply ref, :ok, %{subscriptions: subscriptions}, 1_000
      assert length(subscriptions) == 2

      names = Enum.map(subscriptions, & &1.seed_name) |> Enum.sort()
      assert names == ["sync-host-1", "sync-host-2"]
    end

    test "accepts a policy window without days (daily window)" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      ref =
        push(socket, "subscriptions:sync", %{
          "subscriptions" => [
            %{
              "name" => "daily-window",
              "seed_name" => "daily-window",
              "seed_type" => "nixos",
              "policy" => %{
                "maintenance" => %{
                  "actions" => ["stage", "activate", "restart"],
                  "triggers" => ["scheduled", "poll_on_connect"],
                  "window" => %{
                    "days" => nil,
                    "time_start" => "02:00",
                    "time_end" => "07:00",
                    "tz" => nil
                  }
                }
              }
            }
          ]
        })

      assert_reply ref, :ok, %{subscriptions: [subscription]}, 1_000
      assert subscription.name == "daily-window"

      [stored] = Sower.Orchestration.list_subscriptions_for_garden(garden)
      [policy_rule] = stored.policy
      assert policy_rule.window.days == nil
      assert policy_rule.window.time_start == "02:00"
      assert policy_rule.window.time_end == "07:00"
    end
    test "removes subscriptions not in the sync list" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "to-remove",
        seed_type: "nixos"
      })

      ref =
        push(socket, "subscriptions:sync", %{
          "subscriptions" => [
            %{"name" => "to-keep", "seed_name" => "to-keep", "seed_type" => "nixos"}
          ]
        })

      assert_reply ref, :ok, %{subscriptions: subscriptions}, 1_000
      assert length(subscriptions) == 1
      assert hd(subscriptions).seed_name == "to-keep"

      remaining = Sower.Orchestration.list_subscriptions_for_garden(garden)
      assert length(remaining) == 1
      assert hd(remaining).seed_name == "to-keep"
    end
  end

  describe "garden:seeds:report" do
    test "records garden seed generations" do
      %{socket: socket} = connect_and_join_garden()

      seed = seed_fixture(%{name: "report-seed", seed_type: "nixos"})

      ref =
        push(socket, "garden:seeds:report", %{
          "profiles" => [
            %{
              "profile_path" => "/nix/var/nix/profiles/system",
              "generations" => [
                %{
                  "path" => seed.artifact,
                  "link" => "/nix/var/nix/profiles/system-1-link",
                  "created" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "generation_number" => 1,
                  "is_current" => true
                }
              ]
            }
          ]
        })

      assert_reply ref, :ok, :ok, 1_000
    end

    test "handles empty profiles list" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "garden:seeds:report", %{
          "profiles" => []
        })

      assert_reply ref, :ok, :ok, 1_000
    end
  end

  describe "garden:report" do
    test "persists reported version on the garden row" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      ref = push(socket, "garden:report", %{"version" => "1.2.3"})

      assert_reply ref, :ok, _reply, 1_000
      assert Sower.Orchestration.get_garden!(garden.id).version == "1.2.3"
    end
  end
end
