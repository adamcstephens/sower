defmodule Sower.Orchestration.Garden do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Sower.Repo
  alias Sower.Orchestration.Deployment

  require Logger

  @derive {Jason.Encoder, only: [:sid]}
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
    field :org_id, Ecto.UUID
    field :oauth_client_id, :string
    field :version, :string

    has_many :subscriptions, Sower.Orchestration.Subscription
    has_many :deployments, Sower.Orchestration.Deployment
    has_many :garden_seed_generations, Sower.Orchestration.GardenSeedGeneration

    field :latest_deployment, :any, virtual: true

    timestamps()
  end

  @doc false
  def changeset(garden, attrs) do
    garden
    |> cast(attrs, [:name, :org_id, :oauth_client_id, :version])
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

  def get_garden!(id), do: Repo.get!(__MODULE__, id)

  def get_garden_sid!(sid), do: Repo.get_by!(__MODULE__, sid: sid)

  def get_garden_sid(sid), do: Repo.get_by(__MODULE__, sid: sid)

  def get_by_oauth_client_id(client_id),
    do: Repo.get_by(__MODULE__, [oauth_client_id: client_id], skip_org_id: true)

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

  def update_garden_report(
        %__MODULE__{} = garden,
        %SowerClient.Orchestration.GardenReport{} = report
      ) do
    update_garden(garden, %{version: report.version})
  end

  defp delete_existing_client(%__MODULE__{oauth_client_id: nil}), do: :ok

  defp delete_existing_client(%__MODULE__{oauth_client_id: client_id}) do
    try do
      Sower.GardenAuth.delete_client(client_id)
      :ok
    rescue
      Ecto.NoResultsError ->
        Logger.warning(
          msg: "Old Boruta client not found during re-key",
          oauth_client_id: client_id
        )

        :ok
    end
  end

  def delete_garden(%__MODULE__{} = garden) do
    delete_existing_client(garden)
    Repo.delete(garden)
  end

  def change_garden(%__MODULE__{} = garden, attrs \\ %{}) do
    changeset(garden, attrs)
  end
end
