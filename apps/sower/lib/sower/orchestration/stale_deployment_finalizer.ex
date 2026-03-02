defmodule Sower.Orchestration.StaleDeploymentFinalizer do
  use GenServer

  require Logger

  alias Sower.Orchestration

  @default_interval_ms :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    interval_ms =
      Application.get_env(:sower, __MODULE__, [])
      |> Keyword.get(:interval_ms, @default_interval_ms)

    if interval_ms > 0 do
      schedule(interval_ms)
    else
      Logger.debug(msg: "Stale deployment finalizer disabled", interval_ms: interval_ms)
    end

    {:ok, %{interval_ms: interval_ms}}
  end

  @impl GenServer
  def handle_info(:run, %{interval_ms: interval_ms} = state) do
    {:ok, finalized_count} = Orchestration.finalize_stale_deployments()

    if finalized_count > 0 do
      Logger.info(
        msg: "Stale deployment finalizer ran",
        finalized_count: finalized_count
      )
    end

    if interval_ms > 0 do
      schedule(interval_ms)
    end

    {:noreply, state}
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :run, interval_ms)
  end
end
