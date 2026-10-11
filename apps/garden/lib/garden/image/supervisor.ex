defmodule Garden.Image.Supervisor do
  @moduledoc """
  Dedicated image execution subtree with a final, first-stopped drain boundary.

  `:manager`, `:execution_supervisor`, and `:ledger` override child names. The
  ledger name also identifies BEAM-lifetime accounting custody across subtree
  restarts; use the same name when recovering a previously started subtree.
  """
  use Supervisor

  def start_link(options) do
    Supervisor.start_link(
      __MODULE__,
      options,
      name_options(Keyword.get(options, :name, __MODULE__))
    )
  end

  @impl Supervisor
  def init(options) do
    ledger = Keyword.get(options, :ledger, Garden.Image.Ledger)
    manager = Keyword.get(options, :manager, Garden.Image.Manager)
    executions = Keyword.get(options, :execution_supervisor, Garden.Image.ExecutionSupervisor)

    ledger_options =
      Keyword.take(options, [:budgets, :result_limit, :shutdown_ms]) ++
        [name: ledger, parent: self()]

    children = [
      {Garden.Image.Ledger, ledger_options},
      {Garden.Image.ExecutionSupervisor, [name: executions, ledger: ledger]},
      {Garden.Image.Manager, [name: manager, ledger: ledger]},
      {Garden.Image.Drain, [ledger: ledger]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp name_options(nil), do: []
  defp name_options(name), do: [name: name]
end

defmodule Garden.Image.ExecutionSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(options),
    do: DynamicSupervisor.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @impl DynamicSupervisor
  def init(options) do
    :ok = GenServer.call(Keyword.fetch!(options, :ledger), {:attach_supervisor, self()})
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

defmodule Garden.Image.Drain do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def child_spec(options),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, shutdown: :infinity}

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)
    {:ok, Keyword.fetch!(options, :ledger)}
  end

  @impl GenServer
  def terminate(_reason, ledger) do
    result =
      try do
        GenServer.call(ledger, :shutdown, :infinity)
      catch
        :exit, reason -> {:error, {:cleanup_incomplete, {:ledger_unavailable, reason}}}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(msg: "Image subtree cleanup incomplete", reason: inspect(reason))
    end
  end
end
