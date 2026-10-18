defmodule Sower.Orchestration.DeploymentLogBufferTest do
  use ExUnit.Case, async: true

  alias Sower.Orchestration.{Deployment, DeploymentLog, Garden, Seed}
  alias Sower.Orchestration.DeploymentLog.{Buffer, Pool}
  alias SowerClient.Orchestration.SeedDeploymentLog

  setup do
    org_id = Ecto.UUID.generate()
    garden = %Garden{id: 1, org_id: org_id}
    seeds = [%Seed{id: 1, sid: "seed-a"}, %Seed{id: 2, sid: "seed-z"}]

    deployment = %Deployment{
      id: System.unique_integer([:positive]),
      sid: SowerClient.Sid.generate("dpl"),
      org_id: org_id,
      garden_id: garden.id,
      seeds: seeds
    }

    request = %SeedDeploymentLog{
      deployment_sid: deployment.sid,
      seed_sid: "seed-z",
      sequence: 1,
      output: "first\n"
    }

    Phoenix.PubSub.subscribe(Sower.PubSub, "deployment:#{deployment.sid}")
    %{deployment: deployment, garden: garden, request: request}
  end

  test "orders by seed and sequence, preserves gaps, and never replaces or republishes duplicates",
       ctx do
    {pool, _supervisor} = start_pool()
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)

    for request <- [
          %{ctx.request | sequence: 3, output: "third"},
          %{ctx.request | seed_sid: "seed-a", sequence: 2, output: "other seed"},
          %{ctx.request | output: "builder\0message\n"}
        ] do
      assert {:ok, %{}} = Buffer.append(owner, request, ctx.garden)
      assert_receive {:seed_deployment_log, %DeploymentLog{}}
    end

    assert Enum.map(Buffer.list(owner), &{&1.seed_sid, &1.sequence, &1.output}) == [
             {"seed-a", 2, "other seed"},
             {"seed-z", 1, "builder\0message\n"},
             {"seed-z", 3, "third"}
           ]

    assert {:ok, %{}} =
             Buffer.append(owner, %{ctx.request | sequence: 3, output: "replacement"}, ctx.garden)

    refute_receive {:seed_deployment_log, _}
    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | sequence: 2}, ctx.garden)
    assert_receive {:seed_deployment_log, %{sequence: 2}}

    assert Enum.map(Buffer.list(owner), &{&1.seed_sid, &1.sequence}) == [
             {"seed-a", 2},
             {"seed-z", 1},
             {"seed-z", 2},
             {"seed-z", 3}
           ]

    assert List.last(Buffer.list(owner)).output == "third"
  end

  test "chunk eviction follows insertion order and per-seed floors prevent late history resurrection",
       ctx do
    {pool, _supervisor} = start_pool(max_chunks: 2)
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)

    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | sequence: 7}, ctx.garden)

    assert_receive {:seed_deployment_log,
                    %{owner: ^owner, sequence: 7, reset?: true, evicted: []}}

    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | seed_sid: "seed-a"}, ctx.garden)
    assert_receive {:seed_deployment_log, %{seed_sid: "seed-a", reset?: false, evicted: []}}
    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | sequence: 3}, ctx.garden)
    assert_receive {:seed_deployment_log, %{sequence: 3, reset?: false, evicted: [{"seed-z", 7}]}}

    for sequence <- [6, 7] do
      assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | sequence: sequence}, ctx.garden)
    end

    refute_receive {:seed_deployment_log, _}

    assert Enum.map(Buffer.list(owner), &{&1.seed_sid, &1.sequence}) == [
             {"seed-a", 1},
             {"seed-z", 3}
           ]

    assert {:ok, %{}} =
             Buffer.append(owner, %{ctx.request | seed_sid: "seed-a", sequence: 2}, ctx.garden)

    assert_receive {:seed_deployment_log, %{seed_sid: "seed-a", evicted: [{"seed-a", 1}]}}

    assert Enum.map(Buffer.list(owner), &{&1.seed_sid, &1.sequence}) == [
             {"seed-a", 2},
             {"seed-z", 3}
           ]
  end

  test "byte bounds use UTF-8 bytes and publish every eviction only after the retained history changes",
       ctx do
    {pool, _supervisor} = start_pool(max_bytes: 6, max_chunks: 10)
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)

    for request <- [
          %{ctx.request | seed_sid: "seed-a", output: "ab"},
          %{ctx.request | output: "é"},
          %{ctx.request | seed_sid: "seed-a", sequence: 2, output: "cd"}
        ] do
      assert {:ok, %{}} = Buffer.append(owner, request, ctx.garden)
      assert_receive {:seed_deployment_log, %{evicted: []}}
    end

    assert Enum.reduce(Buffer.list(owner), 0, &(byte_size(&1.output) + &2)) == 6

    assert {:ok, %{}} =
             Buffer.append(owner, %{ctx.request | sequence: 2, output: "🙂"}, ctx.garden)

    assert_receive {:seed_deployment_log,
                    %{sequence: 2, reset?: false, evicted: [{"seed-a", 1}, {"seed-z", 1}]}}

    assert Enum.map(Buffer.list(owner), &{&1.seed_sid, &1.sequence, &1.output}) == [
             {"seed-a", 2, "cd"},
             {"seed-z", 2, "🙂"}
           ]

    assert Enum.all?(
             Buffer.list(owner),
             &(&1.owner == owner and &1.reset? == false and &1.evicted == [])
           )
  end

  test "retained output cannot pin a larger incoming binary beyond the configured payload bound",
       ctx do
    {pool, _supervisor} = start_pool(max_bytes: 8192)
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)
    wire_frame = String.duplicate("x", 100_000)
    output = binary_part(wire_frame, 0, 8192)

    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | output: output}, ctx.garden)
    assert [%{output: retained}] = Buffer.list(owner)
    assert retained == output
    assert :binary.referenced_byte_size(retained) == byte_size(retained)
  end

  test "a valid chunk larger than the entire buffer evicts itself without exceeding the byte bound",
       ctx do
    {pool, _supervisor} = start_pool(max_bytes: 3)
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)
    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | output: "éé"}, ctx.garden)
    assert_receive {:seed_deployment_log, %{reset?: true, evicted: [{"seed-z", 1}]}}
    assert Buffer.list(owner) == []
    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | sequence: 2, output: ""}, ctx.garden)
    assert_receive {:seed_deployment_log, %{reset?: false, evicted: []}}
    assert [%{sequence: 2, output: ""}] = Buffer.list(owner)
  end

  test "validates the 16KiB boundary, UTF-8, and positive integer sequences before retaining or publishing",
       ctx do
    {pool, _supervisor} = start_pool()
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)
    boundary = String.duplicate("é", 8192)
    assert {:ok, %{}} = Buffer.append(owner, %{ctx.request | output: boundary}, ctx.garden)
    assert_receive {:seed_deployment_log, %{output: ^boundary}}

    for request <- [
          %{ctx.request | sequence: 2, output: boundary <> "x"},
          %{ctx.request | sequence: 2, output: <<255>>},
          %{ctx.request | sequence: 2, output: nil},
          %{ctx.request | sequence: 0},
          %{ctx.request | sequence: -1},
          %{ctx.request | sequence: 1.5}
        ] do
      assert {:error, :invalid_log_chunk} = Buffer.append(owner, request, ctx.garden)
    end

    refute_receive {:seed_deployment_log, _}
    assert [%{sequence: 1, output: ^boundary}] = Buffer.list(owner)
  end

  test "authorizes the cached garden, organization, deployment, and seed membership without consuming reset",
       ctx do
    {pool, _supervisor} = start_pool()
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)

    assert {:error, :unauthorized} = Buffer.append(owner, ctx.request, %{ctx.garden | id: 2})

    assert {:error, :unauthorized} =
             Buffer.append(owner, ctx.request, %{ctx.garden | org_id: Ecto.UUID.generate()})

    assert {:error, :unauthorized} =
             Buffer.append(
               owner,
               %{ctx.request | deployment_sid: "another-deployment"},
               ctx.garden
             )

    assert {:error, :seed_not_in_deployment} =
             Buffer.append(owner, %{ctx.request | seed_sid: "outsider"}, ctx.garden)

    assert Buffer.list(owner) == []
    refute_receive {:seed_deployment_log, _}
    assert {:ok, %{}} = Buffer.append(owner, ctx.request, ctx.garden)
    assert_receive {:seed_deployment_log, %{reset?: true}}
  end

  test "lookup and deletion of missing history allocate nothing; competing pools share one global owner",
       ctx do
    {first_pool, first_supervisor} = start_pool(max_buffers: 1)
    {second_pool, second_supervisor} = start_pool(max_buffers: 1)

    assert Pool.lookup(ctx.deployment.org_id, ctx.deployment.sid) == nil
    assert :ok = Pool.delete(ctx.deployment)
    assert DynamicSupervisor.which_children(first_supervisor) == []
    assert DynamicSupervisor.which_children(second_supervisor) == []

    results =
      for pool <- [first_pool, second_pool, first_pool, second_pool] do
        Task.async(fn -> Pool.ensure(ctx.deployment, pool) end)
      end
      |> Task.await_many()

    assert [{:ok, owner}] = Enum.uniq(results)
    assert Pool.lookup(ctx.deployment.org_id, ctx.deployment.sid) == owner

    assert length(DynamicSupervisor.which_children(first_supervisor)) +
             length(DynamicSupervisor.which_children(second_supervisor)) == 1

    # Looking up another pool's owner must not make it consume local capacity.
    observer =
      if DynamicSupervisor.which_children(first_supervisor) == [],
        do: first_pool,
        else: second_pool

    assert {:ok, ^owner} = Pool.ensure(ctx.deployment, observer)
    assert {:ok, _} = Pool.ensure(other_deployment(ctx.deployment), observer)
    assert Process.alive?(owner)
  end

  test "capacity evicts the oldest local owner, not the least recently accessed owner", ctx do
    {pool, supervisor} = start_pool(max_buffers: 2)
    second = other_deployment(ctx.deployment)
    third = other_deployment(ctx.deployment)
    {:ok, first_owner} = Pool.ensure(ctx.deployment, pool)
    assert [table] = owned_tables(first_owner)
    {:ok, second_owner} = Pool.ensure(second, pool)
    assert {:ok, ^first_owner} = Pool.ensure(ctx.deployment, pool)
    assert {:ok, third_owner} = Pool.ensure(third, pool)

    refute Process.alive?(first_owner)
    assert :ets.info(table) == :undefined
    eventually(fn -> Pool.lookup(ctx.deployment.org_id, ctx.deployment.sid) == nil end)
    assert Pool.lookup(second.org_id, second.sid) == second_owner
    assert Pool.lookup(third.org_id, third.sid) == third_owner
    assert length(DynamicSupervisor.which_children(supervisor)) == 2
  end

  test "terminal deletion synchronously destroys the owner table and releases its pool slot",
       ctx do
    {pool, _supervisor} = start_pool(max_buffers: 2)
    second = other_deployment(ctx.deployment)
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)
    {:ok, second_owner} = Pool.ensure(second, pool)
    assert {:ok, %{}} = Buffer.append(owner, ctx.request, ctx.garden)
    assert_receive {:seed_deployment_log, _}
    assert [table] = owned_tables(owner)

    assert :ok = Pool.delete(%{ctx.deployment | state: :completed})
    refute Process.alive?(owner)
    assert :ets.info(table) == :undefined
    eventually(fn -> Pool.lookup(ctx.deployment.org_id, ctx.deployment.sid) == nil end)
    assert :ok = Pool.delete(ctx.deployment)
    assert {:ok, _} = Pool.ensure(other_deployment(ctx.deployment), pool)
    assert Process.alive?(second_owner)
  end

  test "crashes lose history without automatic restart, and ingestion recreates a fresh reset owner",
       ctx do
    {pool, supervisor} = start_pool(max_buffers: 2)
    {:ok, owner} = Pool.ensure(ctx.deployment, pool)
    assert {:ok, %{}} = Buffer.append(owner, ctx.request, ctx.garden)
    assert_receive {:seed_deployment_log, %{reset?: true}}
    assert [table] = owned_tables(owner)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    eventually(fn ->
      Pool.lookup(ctx.deployment.org_id, ctx.deployment.sid) == nil and
        DynamicSupervisor.which_children(supervisor) == []
    end)

    assert :ets.info(table) == :undefined
    assert {:ok, replacement} = Pool.ensure(ctx.deployment, pool)
    assert replacement != owner
    assert Buffer.list(replacement) == []
    assert {:ok, %{}} = Buffer.append(replacement, ctx.request, ctx.garden)

    assert_receive {:seed_deployment_log,
                    %{owner: ^replacement, sequence: 1, reset?: true, evicted: []}}

    assert [%{owner: ^replacement, sequence: 1, output: "first\n"}] = Buffer.list(replacement)

    assert {:ok, _} = Pool.ensure(other_deployment(ctx.deployment), pool)
    assert Process.alive?(replacement)
  end

  test "restarting pool accounting discards surviving ephemeral owners before accepting new ones",
       ctx do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, orphan} =
      DynamicSupervisor.start_child(supervisor, {Buffer, deployment: ctx.deployment})

    assert [table] = owned_tables(orphan)

    pool = start_supervised!({Pool, name: nil, supervisor: supervisor, max_buffers: 1})
    refute Process.alive?(orphan)
    assert :ets.info(table) == :undefined
    eventually(fn -> Pool.lookup(ctx.deployment.org_id, ctx.deployment.sid) == nil end)
    assert {:ok, owner} = Pool.ensure(ctx.deployment, pool)
    assert {:ok, %{}} = Buffer.append(owner, ctx.request, ctx.garden)
    assert [%{sequence: 1}] = Buffer.list(owner)
    assert length(DynamicSupervisor.which_children(supervisor)) == 1
  end

  defp start_pool(opts \\ []) do
    supervisor =
      start_supervised!(
        Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: make_ref())
      )

    pool =
      start_supervised!(
        Supervisor.child_spec(
          {Pool, Keyword.merge([name: nil, supervisor: supervisor], opts)},
          id: make_ref()
        )
      )

    {pool, supervisor}
  end

  defp other_deployment(%Deployment{} = deployment) do
    %{deployment | id: System.unique_integer([:positive]), sid: SowerClient.Sid.generate("dpl")}
  end

  defp owned_tables(owner), do: Enum.filter(:ets.all(), &(:ets.info(&1, :owner) == owner))

  defp eventually(fun, retries \\ 100) do
    if fun.() do
      :ok
    else
      assert retries > 0
      Process.sleep(5)
      eventually(fun, retries - 1)
    end
  end
end
