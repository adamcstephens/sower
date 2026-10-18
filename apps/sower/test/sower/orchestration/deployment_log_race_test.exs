defmodule Sower.Orchestration.DeploymentLogRaceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Sower.Repo
  alias Sower.Orchestration.{Deployment, DeploymentLog}

  test "first buffer creation waits for terminal cleanup and cannot recreate history" do
    {org, garden, seed, deployment} =
      Sandbox.unboxed_run(Repo, fn ->
        org = organization_fixture()
        Repo.put_org_id(org.org_id)
        garden = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})
        seed = seed_fixture()
        deployment = deployment_fixture(%{garden_id: garden.id, seeds: [seed]})
        {org, garden, seed, deployment}
      end)

    on_exit(fn ->
      DeploymentLog.delete_for_deployment(deployment)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.put_org_id(org.org_id)
        Repo.delete!(deployment)
        Repo.delete!(seed)
        Repo.delete!(garden)
        Repo.delete!(org)
      end)
    end)

    request = %SowerClient.Orchestration.SeedDeploymentLog{
      deployment_sid: deployment.sid,
      seed_sid: seed.sid,
      sequence: 1,
      output: "before terminal"
    }

    parent = self()

    terminal =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.put_org_id(org.org_id)

          Repo.transaction(fn ->
            from(d in Deployment, where: d.id == ^deployment.id, lock: "FOR UPDATE")
            |> Repo.one!()

            send(parent, :terminal_locked)

            receive do
              :finish_terminal -> Deployment.update_deployment(deployment, %{state: :completed})
            after
              5_000 -> Repo.rollback(:terminal_barrier_timeout)
            end
          end)
        end)
      end)

    assert_receive :terminal_locked, 5_000

    ingestion =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.put_org_id(org.org_id)
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:ingestion_backend, backend_pid})
          DeploymentLog.record(request, garden)
        end)
      end)

    try do
      assert_receive {:ingestion_backend, backend_pid}, 5_000
      await_blocked_backend(backend_pid, System.monotonic_time(:millisecond) + 5_000)
      send(terminal.pid, :finish_terminal)
      assert {:ok, {:ok, %Deployment{state: :completed}}} = Task.await(terminal)
      assert {:error, :deployment_terminal} = Task.await(ingestion)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.put_org_id(org.org_id)
        assert DeploymentLog.list(deployment) == []

        assert DeploymentLog.Pool.lookup(org.org_id, deployment.sid) == nil
      end)
    after
      send(terminal.pid, :finish_terminal)
      Task.shutdown(terminal)
      Task.shutdown(ingestion)
    end
  end

  defp await_blocked_backend(backend_pid, deadline) do
    blocked =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[blocked]]} =
          Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend_pid])

        blocked
      end)

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("ingestion did not wait for the deployment lock")

      true ->
        Process.sleep(10)
        await_blocked_backend(backend_pid, deadline)
    end
  end
end
