defmodule VMManager.Supervisor do
  @moduledoc """
  Supervises the runtime supervisor, durable manager and shutdown coordinator.

  The shutdown coordinator is started last so it can drain the manager before
  the manager and runtime supervisor are stopped.
  """

  use Supervisor

  def start_link(options),
    do: Supervisor.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @impl Supervisor
  def init(options) do
    runtime = Keyword.get(options, :runtime_supervisor, VMManager.RuntimeSupervisor)
    manager = Keyword.get(options, :manager_name, VMManager.Manager)

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: runtime},
      {VMManager.Manager, Keyword.merge(options, name: manager, runtime_supervisor: runtime)},
      {VMManager.Shutdown, manager}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule VMManager.Shutdown do
  @moduledoc """
  Requests a manager drain during supervision shutdown.

  Shutdown waits for the manager's response and logs incomplete cleanup; it
  does not turn an unconfirmed cleanup into a successful one.
  """

  use GenServer
  require Logger

  def start_link(manager), do: GenServer.start_link(__MODULE__, manager)

  def child_spec(manager),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [manager]}, shutdown: :infinity}

  @impl GenServer
  def init(manager) do
    Process.flag(:trap_exit, true)
    {:ok, manager}
  end

  @impl GenServer
  def terminate(_reason, manager) do
    result =
      try do
        GenServer.call(manager, :prepare_shutdown, :infinity)
      catch
        :exit, reason -> {:error, {:manager_unavailable, reason}}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(msg: "VM manager shutdown cleanup incomplete", reason: inspect(reason))
    end

    :ok
  end
end
