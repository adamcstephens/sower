defmodule Sower.Orchestration.DeploymentLogTest do
  use Sower.DataCase, async: true

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias Sower.Orchestration.{Deployment, DeploymentLog, SeedDeployment}
  alias SowerClient.Orchestration.SeedDeploymentLog

  setup do
    org = organization_fixture()
    Repo.put_org_id(org.org_id)
    garden = garden_fixture()
    seed = seed_fixture()
    deployment = deployment_fixture(%{garden_id: garden.id, seeds: [seed]})
    on_exit(fn -> DeploymentLog.delete_for_deployment(deployment) end)

    request = %SeedDeploymentLog{
      deployment_sid: deployment.sid,
      seed_sid: seed.sid,
      sequence: 1,
      output: "realizing\n"
    }

    Phoenix.PubSub.subscribe(Sower.PubSub, "deployment:#{deployment.sid}")
    %{org: org, garden: garden, seed: seed, deployment: deployment, request: request}
  end

  test "retains out-of-order chunks and gaps, deduplicates without replacing or publishing",
       ctx do
    assert {:ok, _} =
             DeploymentLog.record(
               %{ctx.request | sequence: 3, output: "activating\n"},
               ctx.garden
             )

    assert_receive {:seed_deployment_log, %{sequence: 3, output: "activating\n"}}
    assert {:ok, _} = DeploymentLog.record(ctx.request, ctx.garden)
    assert_receive {:seed_deployment_log, %{sequence: 1}}

    assert {:ok, _} =
             DeploymentLog.record(%{ctx.request | sequence: 3, output: "duplicate"}, ctx.garden)

    refute_receive {:seed_deployment_log, _}

    assert Enum.map(DeploymentLog.list(ctx.deployment), &{&1.sequence, &1.output}) ==
             [{1, "realizing\n"}, {3, "activating\n"}]

    assert {:ok, _} =
             DeploymentLog.record(
               %{ctx.request | sequence: 2, output: "downloaded\n"},
               ctx.garden
             )

    assert Enum.map(DeploymentLog.list(ctx.deployment), & &1.sequence) == [1, 2, 3]
    assert Enum.all?(DeploymentLog.list(ctx.deployment), &(&1.seed_sid == ctx.seed.sid))

    assert Repo.get_by!(SeedDeployment, [deployment_id: ctx.deployment.id], skip_org_id: true).log ==
             nil
  end

  test "sequence numbers are independent for each seed in a deployment", ctx do
    second_seed = seed_fixture()

    {:ok, deployment} =
      Deployment.update_deployment(ctx.deployment, %{seeds: [ctx.seed, second_seed]})

    assert {:ok, _} = DeploymentLog.record(ctx.request, ctx.garden)

    assert {:ok, _} =
             DeploymentLog.record(
               %{ctx.request | seed_sid: second_seed.sid, output: "second seed"},
               ctx.garden
             )

    assert Map.new(DeploymentLog.list(deployment), &{&1.seed_sid, {&1.sequence, &1.output}}) == %{
             ctx.seed.sid => {1, "realizing\n"},
             second_seed.sid => {1, "second seed"}
           }
  end

  test "rejects another garden and a seed outside the deployment", ctx do
    other_garden = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})
    other_seed = seed_fixture()
    assert {:error, :unauthorized} = DeploymentLog.record(ctx.request, other_garden)

    assert {:error, :seed_not_in_deployment} =
             DeploymentLog.record(%{ctx.request | seed_sid: other_seed.sid}, ctx.garden)

    assert DeploymentLog.list(ctx.deployment) == []
    refute_receive {:seed_deployment_log, _}
  end

  test "tenant scoping hides another organization's deployment", ctx do
    other_org = organization_fixture()
    Repo.put_org_id(other_org.org_id)
    other_garden = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})
    assert {:error, :deployment_not_found} = DeploymentLog.record(ctx.request, other_garden)
    assert DeploymentLog.list(ctx.deployment) == []
    refute_receive {:seed_deployment_log, _}
  end

  test "accepts the byte boundary and rejects oversized multibyte output and nonpositive sequences",
       ctx do
    boundary = String.duplicate("é", 8192)
    assert {:ok, _} = DeploymentLog.record(%{ctx.request | output: boundary}, ctx.garden)
    assert [%{output: ^boundary}] = DeploymentLog.list(ctx.deployment)

    for request <- [
          %{ctx.request | sequence: 2, output: boundary <> "x"},
          %{ctx.request | sequence: 0},
          %{ctx.request | sequence: -1},
          %{ctx.request | sequence: 1.5},
          %{ctx.request | output: <<255>>}
        ] do
      assert {:error, :invalid_log_chunk} = DeploymentLog.record(request, ctx.garden)
    end

    assert [%{output: ^boundary}] = DeploymentLog.list(ctx.deployment)
  end

  test "shared wire schema rejects oversized byte payloads and invalid sequences", ctx do
    params = Map.from_struct(ctx.request)
    assert {:ok, _} = SeedDeploymentLog.cast(%{params | output: String.duplicate("é", 8192)})
    assert {:error, _} = SeedDeploymentLog.cast(%{params | output: String.duplicate("é", 8193)})
    assert {:error, _} = SeedDeploymentLog.cast(%{params | sequence: 0})
  end

  test "preserves valid UTF-8 output including NUL bytes", ctx do
    output = "builder\0message\n"
    assert {:ok, _} = DeploymentLog.record(%{ctx.request | output: output}, ctx.garden)
    assert [%{output: ^output}] = DeploymentLog.list(ctx.deployment)
  end

  test "buffer loss discards temporary history and subsequent output starts fresh", ctx do
    assert {:ok, _} = DeploymentLog.record(ctx.request, ctx.garden)
    owner = DeploymentLog.Pool.lookup(ctx.org.org_id, ctx.deployment.sid)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert DeploymentLog.list(ctx.deployment) == []

    assert {:ok, _} =
             DeploymentLog.record(
               %{ctx.request | sequence: 4, output: "after restart\n"},
               ctx.garden
             )

    assert [%{sequence: 4, output: "after restart\n"}] = DeploymentLog.list(ctx.deployment)
  end

  test "an authorized existing buffer accepts further output without a database connection",
       ctx do
    assert {:ok, _} = DeploymentLog.record(ctx.request, ctx.garden)
    parent = self()
    ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        Repo.put_org_id(ctx.org.org_id)

        result =
          DeploymentLog.record(%{ctx.request | sequence: 2, output: "live output\n"}, ctx.garden)

        send(parent, {ref, result})
      end)

    assert_receive {^ref, {:ok, %{}}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}

    assert Enum.map(DeploymentLog.list(ctx.deployment), & &1.output) == [
             "realizing\n",
             "live output\n"
           ]
  end

  test "rejects nested transactions rather than publishing an uncommitted chunk", ctx do
    assert {:ok, {:error, :transaction_in_progress}} =
             Repo.transaction(fn -> DeploymentLog.record(ctx.request, ctx.garden) end)

    assert DeploymentLog.list(ctx.deployment) == []
    refute_receive {:seed_deployment_log, _}
  end

  test "terminal cleanup leaves authoritative final seed output untouched", ctx do
    assert {:ok, _} = DeploymentLog.record(ctx.request, ctx.garden)

    assert {:ok, _} =
             SeedDeployment.record_seed_result(
               %SowerClient.Orchestration.SeedDeploymentResult{
                 deployment_sid: ctx.deployment.sid,
                 seed_sid: ctx.seed.sid,
                 result: :failure,
                 log: "authoritative final failure"
               },
               ctx.garden
             )

    assert {:ok, _} =
             Deployment.update_deployment(ctx.deployment, %{state: :completed, result: :failure})

    assert DeploymentLog.list(ctx.deployment) == []

    seed_deployment =
      Repo.get_by!(SeedDeployment, [deployment_id: ctx.deployment.id], skip_org_id: true)

    assert seed_deployment.log == "authoritative final failure"
    assert seed_deployment.result == :failure
  end

  for terminal <- [:completed, :stale, :canceled] do
    test "#{terminal} removes buffered chunks and rejects late ingestion and stale status updates",
         ctx do
      assert {:ok, _} = DeploymentLog.record(ctx.request, ctx.garden)

      assert {:ok, updated} =
               Deployment.update_deployment(ctx.deployment, %{state: unquote(terminal)})

      assert DeploymentLog.list(updated) == []
      assert DeploymentLog.list(ctx.deployment) == []
      assert DeploymentLog.Pool.lookup(ctx.org.org_id, ctx.deployment.sid) == nil

      assert {:error, :deployment_terminal} =
               DeploymentLog.record(%{ctx.request | sequence: 2}, ctx.garden)

      assert {:error, :deployment_terminal} =
               Deployment.update_deployment(ctx.deployment, %{state: :acknowledged})

      assert Repo.get!(Deployment, ctx.deployment.id).state == unquote(terminal)
      assert DeploymentLog.Pool.lookup(ctx.org.org_id, ctx.deployment.sid) == nil
    end
  end

  test "old Gardens can send final results without streaming, and final logs remain authoritative",
       ctx do
    assert {:ok, _} =
             SeedDeployment.record_seed_result(
               %SowerClient.Orchestration.SeedDeploymentResult{
                 deployment_sid: ctx.deployment.sid,
                 seed_sid: ctx.seed.sid,
                 result: :success,
                 log: "complete final log"
               },
               ctx.garden
             )

    assert {:ok, _} =
             Deployment.record_deployment(%SowerClient.Orchestration.DeploymentResult{
               deployment_sid: ctx.deployment.sid,
               deployed_at: DateTime.utc_now(),
               result: :success
             })

    assert DeploymentLog.list(ctx.deployment) == []

    seed_deployment =
      Repo.get_by!(SeedDeployment, [deployment_id: ctx.deployment.id], skip_org_id: true)

    assert seed_deployment.log == "complete final log"
    assert seed_deployment.result == :success
  end
end
