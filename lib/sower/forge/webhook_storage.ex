defmodule Sower.Forge.WebhookStorage do
  use GenServer

  @table :webhooks

  # client

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_token(%Sower.Forge.Repository{} = repo) do
    case :ets.match(@table, {repo.id, repo.org_id, :"$3"}) do
      [_ | _] = webhooks ->
        webhooks |> List.flatten()

      _ ->
        {:error, :not_found}
    end
  end

  def put(%Sower.Forge.Repository{} = repo, event_type, payload) do
    case GenServer.call(__MODULE__, {:store_payload, repo.id, repo.org_id, event_type, payload}) do
      {:ok, _} ->
        :ok

      _ ->
        {:error, :failed_to_store_payload}
    end
  end

  # server

  @impl GenServer
  def init(_) do
    _tid = :ets.new(@table, [:named_table, :bag, :protected])

    {:ok, []}
  end

  @impl GenServer
  def handle_call({:store_payload, repository_id, org_id, event_type, payload}, _from, state) do
    :ets.insert(@table, {repository_id, org_id, {event_type, payload}})
    {:reply, {:ok, :stored}, state}
  end
end
