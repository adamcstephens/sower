defmodule Garden.VM.Ledger.Store do
  @moduledoc false
  use GenServer

  # Deliberately unlinked: accounting custody must outlive the replaceable VM
  # and application trees. Its lifetime is the BEAM, not an execution subtree.
  def table(identity) do
    name = {:global, {__MODULE__, identity}}

    case GenServer.start(__MODULE__, identity, name: name) do
      {:ok, pid} -> GenServer.call(pid, :table)
      {:error, {:already_started, pid}} -> GenServer.call(pid, :table)
      {:error, reason} -> exit(reason)
    end
  end

  @impl GenServer
  def init(identity) do
    key = {__MODULE__, identity}

    if :persistent_term.get(key, false) do
      {:stop, :accounting_store_lost}
    else
      table = :ets.new(__MODULE__, [:set, :public])
      :persistent_term.put(key, true)
      {:ok, table}
    end
  end

  @impl GenServer
  def handle_call(:table, _from, table), do: {:reply, table, table}
end
