defmodule Garden.Image.Manager do
  @moduledoc """
  Garden-local, atomic admission and execution-ID lookup.

  The independent ledger owns reservations and terminal results. Clean terminal
  results are retained in completion order up to `result_limit`; failed cleanup
  is never evicted and never releases its reservation. Recovery closes admission
  and drains previous guards without replaying commands.
  """
  use GenServer

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def start(options, server \\ __MODULE__), do: call(server, {:start, options})
  def status(id, server \\ __MODULE__), do: call(server, {:status, id})
  def cancel(id, server \\ __MODULE__), do: call(server, {:cancel, id})
  def await(id, server \\ __MODULE__), do: call(server, {:await, id})
  def shutdown(server \\ __MODULE__), do: call(server, :shutdown)

  defp call(server, request) do
    try do
      ledger = GenServer.call(server, :ledger)
      GenServer.call(ledger, request, :infinity)
    catch
      :exit, reason ->
        if request == :shutdown,
          do: {:error, {:cleanup_incomplete, {:ledger_unavailable, reason}}},
          else: {:error, :draining}
    end
  end

  @impl GenServer
  def init(options) do
    ledger = Keyword.fetch!(options, :ledger)
    :ok = GenServer.call(ledger, {:attach_manager, self()})
    {:ok, ledger}
  end

  @impl GenServer
  def handle_call(:ledger, _from, ledger), do: {:reply, ledger, ledger}
end
