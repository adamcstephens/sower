defmodule Sower.Orchestration.Garden do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false
  import Sower.Authorization

  alias Sower.Repo
  alias Sower.Orchestration.Deployment

  require Logger

  @derive {Jason.Encoder, only: [:sid, :local_sid]}
  @derive {Phoenix.Param, key: :sid}

  @derive {
    Flop.Schema,
    filterable: [],
    sortable: [:name, :inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:name],
      order_directions: [:asc]
    }
  }

  schema "gardens" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :name, :string
    field :local_sid, :string
    field :org_id, Ecto.UUID
    field :oauth_client_id, :string

    has_many :subscriptions, Sower.Orchestration.Subscription
    has_many :deployments, Sower.Orchestration.Deployment
    has_many :garden_seed_generations, Sower.Orchestration.GardenSeedGeneration

    field :latest_deployment, :any, virtual: true

    timestamps()
  end

  @doc false
  def changeset(garden, attrs) do
    garden
    |> cast(attrs, [:name, :org_id, :local_sid, :oauth_client_id])
    |> validate_required([:name])
  end

  def list_gardens do
    Repo.all(__MODULE__)
  end

  def list_gardens_with_latest_deployment do
    latest_deployment_query =
      from(d in Deployment,
        where: d.garden_id == parent_as(:garden).id,
        order_by: [desc: d.inserted_at],
        limit: 1
      )

    from(a in __MODULE__,
      as: :garden,
      left_lateral_join: d in subquery(latest_deployment_query),
      on: true,
      select: %{a | latest_deployment: d}
    )
    |> Repo.all()
  end

  def list_gardens_flop(params \\ %{}) do
    latest_deployment_query =
      from(d in Deployment,
        where: d.garden_id == parent_as(:garden).id,
        order_by: [desc: d.inserted_at],
        limit: 1
      )

    query =
      from(a in __MODULE__,
        as: :garden,
        left_lateral_join: d in subquery(latest_deployment_query),
        on: true,
        select: %{a | latest_deployment: d}
      )

    Flop.validate_and_run(query, params, for: __MODULE__)
  end

  def get_garden(
        %SowerClient.GardenHello{
          garden_sid: nil,
          name: name,
          local_sid: local_sid,
          public_key: public_key
        },
        socket
      ) do
    case get_garden_local_sid(local_sid) do
      nil ->
        Logger.debug(
          msg: "Registering new garden",
          name: name,
          local_sid: local_sid
        )

        if socket.assigns.access_token |> can() |> create?(__MODULE__) do
          register_new_garden(%{name: name, local_sid: local_sid, public_key: public_key})
        else
          {:error, :unauthorized}
        end

      %__MODULE__{} = garden ->
        Logger.error(
          msg: "Local garden attempted to re-register existing garden",
          name: garden.name,
          local_sid: local_sid,
          existing_garden_sid: garden.sid
        )

        {:error, :unauthorized_garden_hello}
    end
  end

  def get_garden(
        %SowerClient.GardenHello{
          garden_sid: garden_sid,
          name: name,
          local_sid: local_sid,
          public_key: public_key
        },
        socket
      ) do
    case get_garden_sid(garden_sid) do
      nil ->
        Logger.debug(
          msg: "Local garden requested a missing garden",
          name: name,
          local_sid: local_sid,
          requested_garden_sid: garden_sid
        )

        if socket.assigns.access_token |> can() |> create?(__MODULE__) do
          register_new_garden(%{name: name, local_sid: local_sid, public_key: public_key})
        else
          {:error, :unauthorized}
        end

      %__MODULE__{local_sid: nil} = garden when garden.name == name ->
        Logger.debug(
          msg: "Registering local sid to existing garden",
          name: garden.name,
          local_sid: local_sid,
          garden_sid: garden.sid
        )

        if socket.assigns.access_token |> can() |> create?(__MODULE__) do
          {:ok, garden} = update_garden(garden, %{local_sid: local_sid})
          maybe_provision_oauth_client(garden, public_key)
        else
          {:error, :unauthorized_garden_hello}
        end

      %__MODULE__{} = garden
      when garden.sid == garden_sid and
             garden.name == name and
             garden.local_sid == local_sid ->
        Logger.debug(
          msg: "Found matching garden",
          name: garden.name,
          local_sid: local_sid,
          garden_sid: garden.sid
        )

        maybe_provision_oauth_client(garden, public_key)

      %__MODULE__{} = garden
      when garden.sid == garden_sid and
             garden.name != name and
             garden.local_sid == local_sid ->
        Logger.info(
          msg: "Found matching garden with different name, renaming",
          name: name,
          previous_name: garden.name,
          local_sid: local_sid,
          garden_sid: garden.sid
        )

        {:ok, garden} = update_garden(garden, %{name: name})

        maybe_provision_oauth_client(garden, public_key)

      %__MODULE__{} = garden ->
        Logger.error(
          msg: "Invalid garden request",
          local_sid: local_sid,
          garden_sid: garden.sid
        )

        {:error, :unauthorized_garden_hello}
    end
  end

  def get_garden!(id), do: Repo.get!(__MODULE__, id)

  def get_garden_sid!(sid), do: Repo.get_by!(__MODULE__, sid: sid)

  def get_garden_sid(sid), do: Repo.get_by(__MODULE__, sid: sid)

  def get_by_oauth_client_id(client_id),
    do: Repo.get_by(__MODULE__, [oauth_client_id: client_id], skip_org_id: true)

  def get_garden_local_sid(local_sid), do: Repo.get_by(__MODULE__, local_sid: local_sid)

  def get_garden_local_sid!(local_sid), do: Repo.get_by!(__MODULE__, local_sid: local_sid)

  def register_new_garden(%{public_key: public_key} = attrs) do
    with {:ok, garden} <- create_garden(attrs),
         {:ok, client} <- Sower.GardenAuth.create_client(garden.sid, public_key),
         {:ok, garden} <- update_garden(garden, %{oauth_client_id: client.id}) do
      {:ok, garden, %{client_id: client.id}}
    else
      {:error, reason} ->
        Logger.error(msg: "Failed to register new garden with OAuth", error: inspect(reason))
        {:error, reason}
    end
  end

  defp maybe_provision_oauth_client(%__MODULE__{oauth_client_id: nil} = garden, public_key)
       when is_binary(public_key) do
    with {:ok, client} <- Sower.GardenAuth.create_client(garden.sid, public_key),
         {:ok, garden} <- update_garden(garden, %{oauth_client_id: client.id}) do
      {:ok, garden, %{client_id: client.id}}
    else
      {:error, reason} ->
        Logger.error(
          msg: "Failed to provision OAuth client for existing garden",
          garden_sid: garden.sid,
          error: inspect(reason)
        )

        {:ok, garden}
    end
  end

  defp maybe_provision_oauth_client(%__MODULE__{} = garden, _public_key) do
    {:ok, garden}
  end

  def create_garden(attrs \\ %{}) do
    %__MODULE__{
      org_id: Sower.Repo.get_org_id(),
      sid: SowerClient.Sid.generate("grdn")
    }
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update_garden(%__MODULE__{} = garden, attrs) do
    garden
    |> changeset(attrs)
    |> Repo.update()
  end

  def delete_garden(%__MODULE__{} = garden) do
    if garden.oauth_client_id do
      try do
        Sower.GardenAuth.delete_client(garden.oauth_client_id)
      rescue
        Ecto.NoResultsError ->
          Logger.warning(
            msg: "Boruta client not found during garden deletion",
            oauth_client_id: garden.oauth_client_id
          )
      end
    end

    Repo.delete(garden)
  end

  def change_garden(%__MODULE__{} = garden, attrs \\ %{}) do
    changeset(garden, attrs)
  end
end
