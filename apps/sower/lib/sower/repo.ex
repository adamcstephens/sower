defmodule Sower.Repo do
  use Ecto.Repo,
    otp_app: :sower,
    adapter: Ecto.Adapters.Postgres

  require Ecto.Query

  @tenant_key {__MODULE__, :org_id}

  @impl Ecto.Repo
  def init(_context, config) do
    {:ok, Keyword.merge(config, app_config())}
  end

  defp app_config() do
    dbcfg = Application.get_env(:sower, :database)

    if Keyword.get(dbcfg, :ssl, false) do
      Keyword.put(dbcfg, :ssl, cacerts: :public_key.cacerts_get())
    else
      dbcfg
    end
  end

  @doc """
  Enable foreign key multitenancy and require :org_id unless :skip_org_id is passed
  """
  @boruta_tables ["oauth_clients", "oauth_tokens", "oauth_scopes", "oauth_clients_scopes"]

  @impl Ecto.Repo
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:ecto_query] in [:schema_migration, :preload] ||
        opts[:schema_migration] || oban_table?(query) || boruta_table?(query) ->
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, org_id: ^org_id), opts}

      true ->
        raise "expected org_id or skip_org_id to be set"
    end
  end

  defp oban_table?(%{from: %{source: {table, _}}}) when is_binary(table),
    do: String.starts_with?(table, "oban_")

  defp oban_table?(_), do: false

  defp boruta_table?(%{from: %{source: {table, _}}}) when table in @boruta_tables, do: true
  defp boruta_table?(_), do: false

  def put_org_id(org_id) do
    Process.put(@tenant_key, org_id)
  end

  def get_org_id() do
    Process.get(@tenant_key)
  end

  @doc """
  Read the org id by default on operations
  """
  @impl Ecto.Repo
  def default_options(_operation) do
    [org_id: get_org_id()]
  end
end
