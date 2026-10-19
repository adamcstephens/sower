defmodule Sower.Orchestration.Executions do
  @moduledoc "Durable, org-scoped stock-image executions; accepted commands are never replayed."
  import Ecto.Query, except: [update: 2]
  alias Sower.Repo
  alias Sower.Orchestration.Execution
  alias Sower.Orchestration.Executions.{Builder, Event}
  @active ["dispatching", "accepted", "running", "cancelling"]
  @dimensions ["vms", "cpus", "memory", "scratch_bytes"]
  @log_limit 16 * 1024 * 1024

  def choose(candidates, random \\ &Enum.random/1)
  def choose([], _random), do: nil
  def choose(candidates, random), do: random.(candidates)

  def compatible?(request, capability) do
    capability["enabled"] == true and request["system"] in capability["systems"] and
      capability["contract_min"] <= 1 and capability["contract_max"] >= 1 and
      request["network"] in capability["networks"] and
      Enum.all?(@dimensions, fn dimension ->
        amount(request, dimension) <= Map.get(capability["available"], dimension, 0)
      end)
  end

  defp amount(_request, "vms"), do: 1
  defp amount(request, dimension), do: Map.fetch!(request, dimension)

  def submit(
        %SowerClient.Orchestration.Execution.Request{} = request,
        %Sower.Accounts.AccessToken{} = token
      ) do
    attrs = request |> Jason.encode!() |> Jason.decode!()

    execution = %Execution{
      sid: "exec_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      run_sid: "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      org_id: token.org_id,
      actor_sid: token.sid,
      request: attrs,
      queue_reason: "no_eligible_capacity",
      queue_expires_at: DateTime.add(DateTime.utc_now(), queue_wait_ms(), :millisecond)
    }

    with {:ok, execution} <- Repo.insert(execution) do
      wake()
      {:ok, execution}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp queue_wait_ms, do: Application.get_env(:sower, :execution_queue_wait_ms, 3_600_000)
  def get(sid), do: Repo.get_by(Execution, sid: sid)
  def list, do: Repo.all(from e in Execution, order_by: [desc: e.id], limit: 100)
  def active?(%Execution{} = execution), do: execution.state in @active

  def info(%Execution{} = execution) do
    garden = if execution.garden_id, do: Repo.get(Sower.Orchestration.Garden, execution.garden_id)

    %{
      sid: execution.sid,
      state: execution.state,
      request: execution.request,
      run_sid: execution.run_sid,
      actor_sid: execution.actor_sid,
      garden_sid: get_in(garden.sid),
      queue_reason: execution.queue_reason,
      result: execution.result,
      cursor: execution.cursor,
      dropped_log_bytes: execution.dropped_log_bytes,
      inserted_at: execution.inserted_at,
      updated_at: execution.updated_at
    }
    |> Map.reject(fn {key, value} -> key == :result and is_nil(value) end)
  end

  def history(%Execution{} = execution, cursor) do
    events =
      Repo.all(
        from ev in Event,
          where: ev.execution_id == ^execution.id and ev.sequence > ^cursor,
          order_by: ev.sequence,
          limit: 128
      )

    %{
      events: Enum.map(events, & &1.payload),
      cursor:
        case List.last(events) do
          nil -> max(cursor, execution.cursor)
          event -> event.sequence
        end,
      execution: info(execution)
    }
  end

  def cancel(sid) do
    result =
      locked(fn ->
        case Repo.one(from e in Execution, where: e.sid == ^sid, lock: "FOR UPDATE") do
          nil ->
            {:error, :not_found}

          %Execution{state: "queued"} = execution ->
            {:ok,
             finish(execution, "cancelled", %{"error" => "cancelled", "cleanup" => "complete"})}

          execution ->
            if active?(execution) do
              execution = update(execution, state: "cancelling")
              {:ok, execution}
            else
              {:ok, execution}
            end
        end
      end)

    case result do
      {:ok, {:ok, execution}} ->
        if execution.state == "cancelling", do: send_cancel(execution)
        wake()
        {:ok, execution}

      {:ok, error} ->
        error

      {:error, error} ->
        {:error, error}
    end
  end

  def connect(%Sower.Orchestration.Garden{} = garden) do
    locked(fn ->
      case Repo.get(Builder, garden.id) do
        nil ->
          :ok

        previous ->
          fail_session(previous.session, "builder_disconnected")
          Repo.delete!(previous)
      end
    end)

    :ok
  end

  def capability(
        %Sower.Orchestration.Garden{} = garden,
        %SowerClient.Orchestration.Execution.Capability{} = report,
        registered \\ false
      ) do
    capability = report |> Jason.encode!() |> Jason.decode!()

    result =
      locked(fn ->
        previous = Repo.get(Builder, garden.id)

        if registered and (is_nil(previous) or previous.session != report.session) do
          {:error, :stale_session}
        else
          if previous && previous.session != report.session,
            do: fail_session(previous.session, "builder_reconnected")

          builder = %Builder{
            garden_id: garden.id,
            org_id: garden.org_id,
            session: report.session,
            capability: capability,
            expires_at: DateTime.add(DateTime.utc_now(), 10, :second)
          }

          Repo.insert!(builder,
            on_conflict: {:replace, [:session, :capability, :expires_at]},
            conflict_target: :garden_id
          )

          :ok
        end
      end)

    wake()

    case result do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def disconnect(garden_id, session) do
    locked(fn ->
      Repo.delete_all(
        from(b in Builder, where: b.garden_id == ^garden_id and b.session == ^session),
        skip_org_id: true
      )

      fail_session(session, "builder_disconnected")
    end)

    wake()
  end

  def event(
        %Sower.Orchestration.Garden{} = garden,
        %SowerClient.Orchestration.Execution.Event{} = event
      ) do
    locked(fn ->
      execution = Repo.one(from e in Execution, where: e.sid == ^event.sid, lock: "FOR UPDATE")

      cond do
        is_nil(execution) or execution.garden_id != garden.id or
          execution.session != event.session or execution.attempt != event.attempt ->
          {:error, :unauthorized}

        not active?(execution) ->
          reconcile_terminal(execution, event)

        event.sequence <= execution.cursor ->
          :ok

        event.sequence != execution.cursor + 1 and event.kind != "result" ->
          {:error, :sequence_gap}

        true ->
          apply_event(execution, event)
      end
    end)
    |> case do
      {:ok, result} ->
        wake()
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_terminal(%Execution{} = execution, %SowerClient.Orchestration.Execution.Event{
         kind: "result",
         result: %SowerClient.Orchestration.Execution.Result{cleanup: "complete"}
       }) do
    if execution.cancel_pending do
      update(execution,
        cancel_pending: false,
        result: Map.put(execution.result, "cleanup", "complete")
      )
    end

    :ok
  end

  defp reconcile_terminal(%Execution{}, %SowerClient.Orchestration.Execution.Event{}), do: :ok

  defp apply_event(
         %Execution{} = execution,
         %SowerClient.Orchestration.Execution.Event{kind: "log"} = event
       ) do
    with {:ok, bytes} <- Base.decode64(event.bytes || ""),
         true <- byte_size(bytes) <= 65536,
         true <- event.stream in ["stdout", "stderr"] do
      if execution.dropped_log_bytes == 0 and execution.log_bytes + byte_size(bytes) <= @log_limit do
        record(execution, event)

        update(execution,
          cursor: event.sequence,
          log_bytes: execution.log_bytes + byte_size(bytes)
        )
      else
        update(execution,
          cursor: event.sequence,
          dropped_log_bytes: execution.dropped_log_bytes + byte_size(bytes)
        )
      end

      :ok
    else
      _ -> {:error, :invalid_log}
    end
  end

  defp apply_event(%Execution{} = execution, %SowerClient.Orchestration.Execution.Event{} = event) do
    case {execution.state, event.kind} do
      {_, "conflict"} ->
        record(execution, event)
        update(execution, cursor: event.sequence)
        :ok

      {"cancelling", "refused"} ->
        finish(execution, "cancelled", %{"error" => "cancelled", "cleanup" => "complete"})
        :ok

      {"dispatching", "refused"} ->
        update(execution,
          state: "queued",
          garden_id: nil,
          session: nil,
          cursor: 0,
          queue_reason: "local_admission_refused"
        )

        :ok

      {_, "result"} when not is_nil(event.result) ->
        record(execution, event)
        result = event.result |> Jason.encode!() |> Jason.decode!()

        state =
          case event.result do
            %SowerClient.Orchestration.Execution.Result{
              code: 0,
              signal: nil,
              error: nil,
              cleanup: "complete"
            } ->
              "succeeded"

            %SowerClient.Orchestration.Execution.Result{error: "cancelled", cleanup: "complete"} ->
              "cancelled"

            _ ->
              "failed"
          end

        update(execution,
          state: state,
          result: result,
          cursor: event.sequence,
          cancel_pending: result["cleanup"] != "complete"
        )

        :ok

      {state, "accepted"} when state in ["dispatching", "cancelling"] ->
        record(execution, event)

        update(execution,
          state: if(state == "cancelling", do: state, else: "accepted"),
          cursor: event.sequence
        )

        :ok

      {state, "running"} when state in ["accepted", "cancelling"] ->
        record(execution, event)

        update(execution,
          state: if(state == "cancelling", do: state, else: "running"),
          cursor: event.sequence
        )

        :ok

      _ ->
        {:error, :invalid_transition}
    end
  end

  defp record(%Execution{} = execution, %SowerClient.Orchestration.Execution.Event{} = event) do
    Repo.insert!(%Event{
      execution_id: execution.id,
      org_id: execution.org_id,
      sequence: event.sequence,
      payload:
        event
        |> Jason.encode!()
        |> Jason.decode!()
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    })
  end

  defp finish(%Execution{} = execution, state, result),
    do: update(execution, state: state, result: result)

  defp update(%Execution{} = execution, attrs),
    do: execution |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp fail_session(session, reason) do
    Repo.update_all(
      from(e in Execution, where: e.session == ^session and e.state in ^@active),
      [
        set: [
          state: "failed",
          cancel_pending: true,
          result: %{"error" => reason, "cleanup" => "unknown"},
          updated_at: DateTime.utc_now()
        ]
      ],
      skip_org_id: true
    )
  end

  def dispatch(random \\ &Enum.random/1) do
    now = DateTime.utc_now()

    {:ok, commands} =
      locked(fn ->
        expired = Repo.all(from(b in Builder, where: b.expires_at <= ^now), skip_org_id: true)
        Enum.each(expired, &fail_session(&1.session, "builder_disconnected"))
        Repo.delete_all(from(b in Builder, where: b.expires_at <= ^now), skip_org_id: true)

        Repo.update_all(
          from(e in Execution, where: e.state == "queued" and e.queue_expires_at <= ^now),
          [
            set: [
              state: "failed",
              result: %{"error" => "queue_timeout", "cleanup" => "complete"},
              updated_at: now
            ]
          ],
          skip_org_id: true
        )

        Repo.update_all(
          from(e in Execution, where: e.state in ^@active and e.deadline_at <= ^now),
          [
            set: [
              state: "failed",
              cancel_pending: true,
              result: %{"error" => "orchestration_timeout", "cleanup" => "unknown"},
              updated_at: now
            ]
          ],
          skip_org_id: true
        )

        builders = Repo.all(Builder, skip_org_id: true)

        queued =
          Repo.all(from(e in Execution, where: e.state == "queued", order_by: e.id),
            skip_org_id: true
          )

        Enum.reduce(queued, [], fn execution, commands ->
          eligible =
            Enum.filter(builders, fn builder ->
              builder.org_id == execution.org_id and
                compatible?(execution.request, builder.capability) and room?(execution, builder)
            end)

          case choose(eligible, random) do
            nil ->
              commands

            builder ->
              execution =
                update(execution,
                  state: "dispatching",
                  garden_id: builder.garden_id,
                  session: builder.session,
                  attempt: execution.attempt + 1,
                  queue_reason: nil,
                  deadline_at:
                    DateTime.add(now, execution.request["timeout_ms"] + 60_000, :millisecond)
                )

              [execution | commands]
          end
        end)
      end)

    Enum.each(Enum.reverse(commands), fn execution ->
      Phoenix.PubSub.broadcast(
        Sower.PubSub,
        "execution:session:" <> execution.session,
        {:execution_dispatch,
         %{
           sid: execution.sid,
           run_sid: execution.run_sid,
           session: execution.session,
           attempt: execution.attempt,
           request: execution.request
         }}
      )
    end)

    cancelling =
      Repo.all(from(e in Execution, where: e.state == "cancelling" or e.cancel_pending),
        skip_org_id: true
      )

    Enum.each(cancelling, &send_cancel/1)
  end

  defp room?(%Execution{} = execution, %Builder{} = builder) do
    reservations =
      Repo.all(
        from(e in Execution,
          where:
            e.garden_id == ^builder.garden_id and
              (e.state in ^@active or
                 fragment("?->>'cleanup' IN ('incomplete', 'unknown')", e.result))
        ),
        skip_org_id: true
      )

    Enum.all?(@dimensions, fn dimension ->
      reserved = Enum.reduce(reservations, 0, &(amount(&1.request, dimension) + &2))
      reserved + amount(execution.request, dimension) <= builder.capability["budgets"][dimension]
    end)
  end

  defp send_cancel(%Execution{} = execution) do
    Phoenix.PubSub.broadcast(
      Sower.PubSub,
      "execution:session:" <> execution.session,
      {:execution_cancel,
       %{sid: execution.sid, session: execution.session, attempt: execution.attempt}}
    )
  end

  defp locked(fun) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(296)", [])
      fun.()
    end)
  end

  def wake do
    if pid = Process.whereis(Sower.Orchestration.Executions.Dispatcher), do: send(pid, :dispatch)
    :ok
  end
end

defmodule Sower.Orchestration.Executions.Dispatcher do
  use GenServer
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  @impl GenServer
  def init(_options) do
    interval = Application.get_env(:sower, __MODULE__, []) |> Keyword.get(:interval_ms, 1000)
    if interval > 0, do: Process.send_after(self(), :tick, interval)
    {:ok, interval}
  end

  @impl GenServer
  def handle_info(:tick, interval) do
    Process.send_after(self(), :tick, interval)
    handle_info(:dispatch, interval)
  end

  def handle_info(:dispatch, 0), do: {:noreply, 0}

  def handle_info(:dispatch, state) do
    Sower.Orchestration.Executions.dispatch()
    {:noreply, state}
  end
end
