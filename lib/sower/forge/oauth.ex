defmodule Sower.Forge.Oauth do
  use GenServer

  defstruct pkce_table: nil

  @type t :: %__MODULE__{
          pkce_table: :ets.tid()
        }

  @pkce_table :forge_oauth_pkce

  # client

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_connection(%Sower.Forge.Connection{} = forge) do
    case Sower.Forge.Oauth.Supervisor.start_oidcc_worker(%{
           issuer: forge.url,
           name: oidcc_module_name(forge)
         }) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, err} -> {:error, err}
    end
  end

  def create_redirect_url(%Sower.Forge.Connection{} = forge, source_path) do
    {:ok, _pid} = Sower.Forge.Oauth.start_connection(forge)

    case GenServer.call(__MODULE__, {:create_pkce_verifier, forge.id}) do
      {:ok, verifier} ->
        {:ok, url_parts} =
          Oidcc.create_redirect_url(
            oidcc_module_name(forge),
            forge.client_id,
            forge.client_secret,
            %{
              redirect_uri:
                "#{Application.fetch_env!(:sower, :public_url)}/forges/oauth/callback",
              require_pkce: true,
              pkce_verifier: verifier,
              url_extension: [{"source_path", source_path}]
            }
          )

        {:ok, url_parts |> Enum.join("")}

      {:error, err} ->
        {:error, err}
    end
  end

  def retrieve_token(%Sower.Forge.Connection{} = forge, auth_code) do
    {:ok, _pid} = Sower.Forge.Oauth.start_connection(forge)

    case GenServer.call(__MODULE__, {:create_pkce_verifier, forge.id}) do
      {:ok, verifier} ->
        Oidcc.retrieve_token(
          auth_code,
          oidcc_module_name(forge),
          forge.client_id,
          forge.client_secret,
          %{
            redirect_uri: "#{Application.fetch_env!(:sower, :public_url)}/forges/oauth/callback",
            require_pkce: true,
            pkce_verifier: verifier
          }
        )

      {:error, err} ->
        {:error, err}
    end
  end

  defp oidcc_module_name(%Sower.Forge.Connection{} = forge) do
    String.to_atom("Sower.Forge.Oidcc#{forge.id}")
  end

  # server

  @impl GenServer
  def init(_) do
    {:ok, _pid} = Sower.Forge.Oauth.Supervisor.start_link()

    {:ok, %__MODULE__{pkce_table: :ets.new(@pkce_table, [:set, :private])}} |> dbg()
  end

  @impl GenServer
  def handle_call({:create_pkce_verifier, forge_id}, _from, state) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.encode64()

    :ets.insert(state.pkce_table, {forge_id, verifier})

    {:reply, {:ok, verifier}, state}
  end

  @impl GenServer
  def handle_call({:lookup_pkce_verifier, forge_id}, _from, state) do
    case :ets.lookup(state.pkce_table, forge_id) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^forge_id, verified_for_id}] ->
        {:reply, verified_for_id, state}

      _ ->
        {:reply, {:error, :unknown_error}, state}
    end
  end

  @impl GenServer
  def handle_call({:start_provider, forge_id}, _from, state) do
    case :ets.lookup(state.pkce_table, forge_id) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^forge_id, verified_for_id}] ->
        {:reply, verified_for_id, state}

      _ ->
        {:reply, {:error, :unknown_error}, state}
    end
  end

  defmodule Supervisor do
    use DynamicSupervisor

    def start_link(arg \\ []) do
      DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
    end

    def start_oidcc_worker(worker_opts) do
      DynamicSupervisor.start_child(__MODULE__, {Oidcc.ProviderConfiguration.Worker, worker_opts})
    end

    @impl true
    def init(_) do
      DynamicSupervisor.init(strategy: :one_for_one)
    end
  end
end
