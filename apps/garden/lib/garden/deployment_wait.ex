defmodule Garden.DeploymentWait do
  @moduledoc """
  Observes one explicitly requested deployment until every seed worker starts.

  The admin connection owns the observation. Request IDs isolate concurrent
  triggers; the deployment manifest fixes the expected seed membership. Only
  worker start messages resolve a seed successfully. Deadlines and disconnects
  end observation, never deployment work.
  """

  use TypedStruct

  alias SowerClient.Orchestration.Subscription

  typedstruct module: Watch do
    @moduledoc "Socket-side request correlation, removed when the observer exits."
    field :pid, pid(), enforce: true
    field :monitor, reference(), enforce: true
    field :ref, String.t(), enforce: true
  end

  typedstruct module: State do
    @moduledoc "Connection-owned observation with an absolute monotonic deadline."
    field :request_id, String.t(), enforce: true
    field :subscription, Subscription.t(), enforce: true
    field :deadline, integer(), enforce: true
    field :emit, function(), enforce: true
    field :deployment, struct()
    field :pending, map(), default: %{}
  end

  def observe(request_id, %Subscription{} = subscription, timeout_ms, emit) do
    state = %State{
      request_id: request_id,
      subscription: subscription,
      deadline: System.monotonic_time(:millisecond) + timeout_ms,
      emit: emit
    }

    emit.(:ok, "waiting for acceptance #{identity(state)}")
    await(state)
  end

  defp await(%State{} = state) do
    request_id = state.request_id
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:deployment_wait, ^request_id, :accepted} ->
        state.emit.(:ok, "accepted request #{state.request_id}; waiting for execution start")
        await(state)

      {:deployment_wait, ^request_id, {:deployment, deployment}} ->
        pending = Map.new(deployment.seed_deployments, &{&1.seed.sid, &1.seed})
        state = %{state | deployment: deployment, pending: pending}

        Enum.each(pending, fn {_sid, seed} ->
          state.emit.(:ok, "accepted #{seed_identity(seed, deployment.sid)}")
          state.emit.(:ok, "waiting #{seed_identity(seed, deployment.sid)}")
        end)

        cond do
          deployment.skipped -> fail(state, "failed-to-start", "skipped; already deployed")
          map_size(pending) == 0 -> fail(state, "failed-to-start", "no seeds accepted")
          true -> await(state)
        end

      {:deployment_wait, ^request_id, {:started, sid}} when not is_nil(state.deployment) ->
        case Map.pop(state.pending, sid) do
          {nil, _} ->
            await(state)

          {seed, pending} ->
            state.emit.(:ok, "started #{seed_identity(seed, state.deployment.sid)}")
            if map_size(pending) == 0, do: 0, else: await(%{state | pending: pending})
        end

      {:deployment_wait, ^request_id, {:rejected, reason}} ->
        fail(state, "failed-to-start", reason)

      {:deployment_wait, ^request_id, :disconnected} ->
        if state.deployment do
          await(state)
        else
          fail(state, "start unconfirmed", "server disconnected; work may still run")
        end

      {:DOWN, _ref, :process, _pid, _reason} ->
        if state.deployment do
          await(state)
        else
          fail(state, "start unconfirmed", "garden socket stopped; work may still run")
        end

      {:tcp_closed, _client} ->
        1

      {:tcp_error, _client, _reason} ->
        1
    after
      remaining -> fail(state, "start unconfirmed", "timed out; work may still run")
    end
  end

  defp fail(%State{} = state, outcome, reason) do
    if map_size(state.pending) == 0 do
      state.emit.(:error, "#{outcome} #{identity(state)}: #{reason}")
    else
      Enum.each(state.pending, fn {_sid, seed} ->
        state.emit.(:error, "#{outcome} #{seed_identity(seed, state.deployment.sid)}: #{reason}")
      end)
    end

    1
  end

  defp identity(%State{} = state) do
    "#{state.subscription.seed_name} (#{state.subscription.seed_type}), request #{state.request_id}, deployment unavailable"
  end

  defp seed_identity(seed, deployment_sid) do
    "#{seed.name} (#{seed.seed_type}), deployment #{deployment_sid}"
  end
end
