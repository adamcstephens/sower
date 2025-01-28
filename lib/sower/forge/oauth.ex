defmodule Sower.Forge.Oauth do
  use GenServer

  @pkce_table :forge_oauth_pkce
  @token_table :forge_tokens

  # client

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_connection(%Sower.Forge.Connection{type: :forgejo} = forge) do
    case Sower.Forge.Oauth.Supervisor.start_oidcc_worker(%{
           issuer: forge.url,
           name: oidcc_module_name(forge),
           provider_configuration_opts: %{
             quirks: %{
               document_overrides: %{
                 "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
               }
             }
           }
         }) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, err} -> {:error, err}
    end
  end

  def create_redirect_url(%Sower.Forge.Connection{} = forge) do
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
              pkce_verifier: verifier
            }
          )

        {:ok, url_parts |> Enum.join("")}

      {:error, err} ->
        {:error, err}
    end
  end

  def get_token(forge_id, user_id) do
    case :ets.match(@token_table, {forge_id, user_id, :"$3"}) do
      [[token]] -> {:ok, token}
      _ -> {:error, :not_found}
    end
  end

  def logged_in?(forge_id, user_id) do
    case get_token(forge_id, user_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def retrieve_token(%Sower.Forge.Connection{} = forge, auth_code) do
    {:ok, _pid} = Sower.Forge.Oauth.start_connection(forge)

    case :ets.lookup(@pkce_table, forge.id) do
      [] ->
        {:error, :not_found}

      [{_id, verifier}] ->
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

      _ ->
        {:error, :unknown_error}
    end
  end

  def set_token(%Oidcc.Token{} = token, forge_id, user_id) do
    case GenServer.call(__MODULE__, {:store_auth_token, forge_id, user_id, token}) do
      {:ok, _} ->
        :ok

      _ ->
        {:error, :failed_to_store_token}
    end
  end

  defp oidcc_module_name(%Sower.Forge.Connection{} = forge) do
    String.to_atom("Sower.Forge.Oidcc#{forge.id}")
  end

  # server

  @impl GenServer
  def init(_) do
    {:ok, _pid} = Sower.Forge.Oauth.Supervisor.start_link()
    _tid = :ets.new(@pkce_table, [:named_table, :set, :protected])
    _tid = :ets.new(@token_table, [:named_table, :set, :protected])

    {:ok, []}
  end

  @impl GenServer
  def handle_call({:create_pkce_verifier, forge_id}, _from, state) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    :ets.insert(@pkce_table, {forge_id, verifier})

    {:reply, {:ok, verifier}, state}
  end

  @impl GenServer
  def handle_call({:store_auth_token, forge_id, user_id, token}, _from, state) do
    :ets.insert(@token_table, {forge_id, user_id, token})
    {:reply, {:ok, :stored}, state}
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
