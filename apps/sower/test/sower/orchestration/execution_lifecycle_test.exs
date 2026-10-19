defmodule Sower.Orchestration.ExecutionLifecycleTest do
  use Sower.DataCase, async: false
  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  alias Sower.Orchestration.Executions
  alias Sower.Orchestration.Execution
  alias Sower.Orchestration.Executions.Builder

  setup do
    org = organization_fixture()
    Repo.put_org_id(org.org_id)
    garden = garden_fixture()
    token = %Sower.Accounts.AccessToken{org_id: org.org_id, sid: "actor"}

    request =
      SowerClient.Orchestration.Execution.Request.cast!(%{
        system: "x86_64-linux",
        path: "/bin/true",
        stdin: %{},
        cpus: 1,
        memory: 536_870_912,
        scratch_bytes: 1_073_741_824
      })

    %{garden: garden, token: token, request: request}
  end

  defp capability(garden, session \\ "session") do
    report =
      SowerClient.Orchestration.Execution.Capability.cast!(%{
        session: session,
        enabled: true,
        systems: ["x86_64-linux"],
        contract_min: 1,
        contract_max: 1,
        networks: ["none"],
        budgets: %{vms: 1, cpus: 1, memory: 536_870_912, scratch_bytes: 1_073_741_824},
        available: %{vms: 1, cpus: 1, memory: 536_870_912, scratch_bytes: 1_073_741_824}
      })

    Executions.capability(garden, report)
  end

  defp event(execution, kind, sequence, attrs \\ %{}) do
    SowerClient.Orchestration.Execution.Event.cast!(
      Map.merge(
        %{
          sid: execution.sid,
          session: execution.session,
          attempt: execution.attempt,
          sequence: sequence,
          kind: kind
        },
        attrs
      )
    )
  end

  test "disconnected queue persists and queued cancellation allocates nothing", context do
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assert Executions.get(queued.sid).state == "queued"
    assert {:ok, cancelled} = Executions.cancel(queued.sid)
    assert cancelled.state == "cancelled"
    assert cancelled.garden_id == nil
    capability(context.garden)
    Executions.dispatch()
    assert Executions.get(queued.sid).state == "cancelled"
  end

  test "reserves capacity before sending and dispatches older compatible work first", context do
    capability(context.garden)
    {:ok, first} = Executions.submit(context.request, context.token)
    {:ok, second} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assigned = Executions.get(first.sid)
    assert assigned.state == "dispatching"
    assert assigned.garden_id == context.garden.id
    assert Executions.get(second.sid).state == "queued"
    Executions.dispatch()
    assert Executions.get(second.sid).state == "queued"
    assert Executions.get(first.sid).attempt == 1
  end

  test "commits ordered binary logs once and preserves signal plus terminal authority", context do
    capability(context.garden)
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    execution = Executions.get(queued.sid)
    accepted = event(execution, "accepted", 1)
    assert :ok = Executions.event(context.garden, accepted)
    assert :ok = Executions.event(context.garden, accepted)
    assert :ok = Executions.event(context.garden, event(execution, "running", 2))
    output = event(execution, "log", 3, %{stream: "stderr", bytes: Base.encode64(<<0, 255, 10>>)})
    assert :ok = Executions.event(context.garden, output)
    assert :ok = Executions.event(context.garden, output)

    assert :ok =
             Executions.event(
               context.garden,
               event(execution, "result", 4, %{
                 result: %{code: nil, signal: 15, cleanup: "complete"}
               })
             )

    final = Executions.get(execution.sid)
    assert final.state == "failed"
    assert %{"code" => nil, "signal" => 15, "cleanup" => "complete"} = final.result
    history = Executions.history(final, 1)
    assert Enum.map(history.events, & &1["sequence"]) == [2, 3, 4]
    assert Enum.at(history.events, 1)["bytes"] |> Base.decode64!() == <<0, 255, 10>>

    assert :ok =
             Executions.event(
               context.garden,
               event(execution, "result", 5, %{result: %{code: 0, cleanup: "complete"}})
             )

    assert Executions.get(execution.sid).result == final.result
  end

  test "certified preaccept refusal requeues but old-attempt events cannot mutate reassignment",
       context do
    capability(context.garden)
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    first = Executions.get(queued.sid)
    assert :ok = Executions.event(context.garden, event(first, "refused", 1))
    assert Executions.get(first.sid).state == "queued"
    Executions.dispatch()
    second = Executions.get(first.sid)
    assert second.attempt == 2
    assert {:error, :unauthorized} = Executions.event(context.garden, event(first, "accepted", 1))
    assert second == Executions.get(first.sid)
  end

  test "disconnect fails ambiguity and reconnect never queues accepted commands again", context do
    capability(context.garden)
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    execution = Executions.get(queued.sid)
    Executions.disconnect(context.garden.id, execution.session)
    final = Executions.get(execution.sid)
    assert final.state == "failed"
    assert final.result["error"] == "builder_disconnected"
    capability(context.garden, "new-session")
    Executions.dispatch()
    assert Executions.get(execution.sid) == final
  end

  test "fresh capacity cannot release an uncertain prior assignment without its teardown certificate",
       context do
    capability(context.garden)
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assigned = Executions.get(queued.sid)
    Executions.disconnect(context.garden.id, assigned.session)
    capability(context.garden, "fresh-session")
    {:ok, waiting} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assert Executions.get(waiting.sid).state == "queued"
    assert Executions.get(assigned.sid).result["cleanup"] == "unknown"

    assert :ok =
             Executions.event(
               context.garden,
               event(assigned, "result", 1, %{result: %{error: "cancelled", cleanup: "complete"}})
             )

    final = Executions.get(assigned.sid)
    assert final.state == "failed"
    assert final.result == %{"error" => "builder_disconnected", "cleanup" => "complete"}
    Executions.dispatch()
    assert Executions.get(waiting.sid).state == "dispatching"
  end

  test "queue timeout is separate from guest execution timeout", context do
    {:ok, queued} = Executions.submit(context.request, context.token)

    queued
    |> Ecto.Changeset.change(queue_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    Executions.dispatch()
    final = Executions.get(queued.sid)
    assert final.result["error"] == "queue_timeout"
    assert final.garden_id == nil
    assert final.request["timeout_ms"] == context.request.timeout_ms
  end

  test "wrong organization builders and unassigned gardens cannot acquire or alter execution",
       context do
    {:ok, queued} = Executions.submit(context.request, context.token)
    org_id = context.token.org_id
    other = organization_fixture()
    Repo.put_org_id(other.org_id)
    other_garden = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})
    capability(other_garden, "other-session")
    Repo.put_org_id(org_id)
    Executions.dispatch()
    assert Executions.get(queued.sid).state == "queued"
    capability(context.garden)
    Executions.dispatch()
    execution = Executions.get(queued.sid)

    assert {:error, :unauthorized} =
             Executions.event(other_garden, event(execution, "accepted", 1))

    Repo.put_org_id(other.org_id)
    assert Executions.get(queued.sid) == nil
    assert {:error, :not_found} = Executions.cancel(queued.sid)
    assert Repo.aggregate(Execution, :count) == 0
    assert Repo.aggregate(Builder, :count) == 1
  end

  test "incompatible older requests do not block later work and injected random choice can select either eligible garden",
       context do
    capability(context.garden)
    other = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})
    capability(other, "second")
    {:ok, incompatible} = Executions.submit(%{context.request | network: "full"}, context.token)
    {:ok, first} = Executions.submit(context.request, context.token)
    Executions.dispatch(&Enum.min_by(&1, fn builder -> builder.garden_id end))
    assert Executions.get(incompatible.sid).state == "queued"
    assert Executions.get(first.sid).garden_id == min(context.garden.id, other.id)
    assigned = Executions.get(first.sid)
    garden = if assigned.garden_id == other.id, do: other, else: context.garden

    assert :ok =
             Executions.event(
               garden,
               event(assigned, "result", 1, %{result: %{code: 0, cleanup: "complete"}})
             )

    {:ok, second} = Executions.submit(context.request, context.token)
    Executions.dispatch(&Enum.max_by(&1, fn builder -> builder.garden_id end))
    assert Executions.get(second.sid).garden_id == max(context.garden.id, other.id)
  end

  test "cancellation racing dispatch acceptance keeps cancellation pending until certified result",
       context do
    capability(context.garden)
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assigned = Executions.get(queued.sid)
    assert {:ok, %{state: "cancelling"}} = Executions.cancel(assigned.sid)
    assert :ok = Executions.event(context.garden, event(assigned, "accepted", 1))
    assert Executions.get(assigned.sid).state == "cancelling"

    assert :ok =
             Executions.event(
               context.garden,
               event(assigned, "result", 2, %{result: %{error: "cancelled", cleanup: "complete"}})
             )

    assert Executions.get(assigned.sid).state == "cancelled"
  end

  test "cleanup reconciliation releases retained accounting without replacing the terminal outcome",
       context do
    capability(context.garden)
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assigned = Executions.get(queued.sid)

    assert :ok =
             Executions.event(
               context.garden,
               event(assigned, "result", 1, %{
                 result: %{
                   code: 0,
                   cleanup: "incomplete",
                   cleanup_error: "network release failed"
                 }
               })
             )

    {:ok, waiting} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assert Executions.get(waiting.sid).state == "queued"

    assert :ok =
             Executions.event(
               context.garden,
               event(assigned, "result", 2, %{result: %{code: 37, cleanup: "complete"}})
             )

    final = Executions.get(assigned.sid)
    assert final.state == "failed"

    assert %{"code" => 0, "cleanup" => "complete", "cleanup_error" => "network release failed"} =
             final.result

    Executions.dispatch()
    assert Executions.get(waiting.sid).state == "dispatching"
  end

  test "retention discards only stream bytes and never hides terminal status behind dropped cursors",
       context do
    capability(context.garden)
    {:ok, queued} = Executions.submit(context.request, context.token)
    Executions.dispatch()
    assigned = Executions.get(queued.sid)
    assigned |> Ecto.Changeset.change(log_bytes: 16 * 1024 * 1024) |> Repo.update!()
    assert :ok = Executions.event(context.garden, event(assigned, "accepted", 1))

    assert :ok =
             Executions.event(
               context.garden,
               event(assigned, "log", 2, %{stream: "stdout", bytes: Base.encode64("discarded")})
             )

    Executions.disconnect(context.garden.id, assigned.session)
    final = Executions.get(assigned.sid)
    assert final.dropped_log_bytes == 9
    history = Executions.history(final, 1)
    assert history.events == []
    assert history.cursor == final.cursor
    assert history.execution.state == "failed"
  end
end
