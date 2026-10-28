defmodule Garden.VM.Manager do
  @moduledoc """
  Garden-local atomic VM admission and VM-ID lookup.

  `boot/3`, `await_ready/2`, `execute/4` and `stop/2` expose owned VMs.
  `start/2`, `await/2` and `cancel/2` preserve disposable execution semantics.
  Commands use `Garden.VM` command handles, not manager VM IDs.
  The independent ledger holds VM/CPU/memory/scratch reservations while idle
  as well as busy, releasing only after certified teardown. Clean terminal
  results are retained in completion order up to `result_limit`; uncertain
  cleanup is never evicted or released. Recovery drains without replay.
  """
  use GenServer

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def start(options, server \\ __MODULE__), do: call(server, {:start, options})
  def list(server \\ __MODULE__), do: call(server, :list)
  def status(id, server \\ __MODULE__), do: call(server, {:status, id})
  def cancel(id, server \\ __MODULE__), do: call(server, {:cancel, id})
  def await(id, server \\ __MODULE__), do: call(server, {:await, id})
  def shutdown(server \\ __MODULE__), do: call(server, :shutdown)

  def boot(image, options \\ [], server \\ __MODULE__),
    do:
      start(
        Keyword.merge(options, image: image, owner: Keyword.get(options, :owner, self()))
        |> Keyword.delete(:command),
        server
      )

  def await_ready(id, server \\ __MODULE__),
    do: with_execution(id, server, &Garden.VM.await_ready/1)

  def execute(id, command, options \\ [], server \\ __MODULE__),
    do: with_execution(id, server, &Garden.VM.execute(&1, command, options))

  def stop(id, server \\ __MODULE__), do: call(server, {:stop, id})

  defp with_execution(id, server, fun) do
    with {:ok, status} <- status(id, server),
         true <- status.phase not in [:finished, :stopped, :retained] do
      try do
        fun.(status.execution)
      catch
        :exit, _reason -> {:error, :vm_unavailable}
      end
    else
      false -> {:error, :vm_unavailable}
      error -> error
    end
  end

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
