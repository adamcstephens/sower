defmodule Sower.Orchestration.GardenSeedGeneration do
  @moduledoc "Persists profile-local generation identity and reconciles authoritative Garden observations."
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Sower.Repo
  alias Sower.Orchestration.{Garden, GardenPubSub, NixProfile, Seed}

  require Logger

  schema "garden_seed_generations" do
    field :org_id, Ecto.UUID

    belongs_to :garden, Garden
    belongs_to :seed, Seed
    belongs_to :profile, NixProfile

    field :generation_number, :integer
    field :generation_id, :string
    field :generation_path, :string
    field :is_staged, :boolean, default: false
    field :pinned, :boolean, default: false
    field :managed, :boolean, default: false
    field :is_current, :boolean, default: false
    field :created_at_generation, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = garden_seed_generation, attrs) do
    garden_seed_generation
    |> cast(attrs, [
      :org_id,
      :garden_id,
      :seed_id,
      :profile_id,
      :generation_number,
      :generation_id,
      :generation_path,
      :is_staged,
      :pinned,
      :managed,
      :is_current,
      :created_at_generation
    ])
    |> put_generation_identity()
    |> validate_required([:org_id, :garden_id, :seed_id, :profile_id, :created_at_generation])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:garden_id)
    |> foreign_key_constraint(:seed_id)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:garden_id, :profile_id, :generation_id],
      name: :garden_profile_generation_identity_index
    )
  end

  defp put_generation_identity(changeset) do
    if get_field(changeset, :generation_id) do
      changeset
    else
      identity =
        case get_field(changeset, :generation_number) do
          nil -> "legacy:seed:#{get_field(changeset, :seed_id)}"
          number -> "legacy:#{number}"
        end

      put_change(changeset, :generation_id, identity)
    end
  end

  def list_garden_seed_generation(%Garden{id: garden_id}) do
    from(asg in __MODULE__,
      where: asg.garden_id == ^garden_id,
      order_by: [desc: asg.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  def list_current_seed_generation(%Garden{id: garden_id}) do
    from(asg in __MODULE__,
      where: asg.garden_id == ^garden_id and asg.is_current == true,
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  def list_garden_seed_generation_profile(garden_id, profile_id) do
    from(asg in __MODULE__,
      where: asg.garden_id == ^garden_id and asg.profile_id == ^profile_id,
      order_by: [desc: asg.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  def upsert_garden_generation(garden_id, profile_id, seed_id, attrs) do
    generation_id =
      Map.get(attrs, :generation_id) ||
        if(attrs.generation_number,
          do: "legacy:#{attrs.generation_number}",
          else: "legacy:seed:#{seed_id}"
        )

    changeset_attrs = %{
      org_id: Repo.get_org_id(),
      garden_id: garden_id,
      seed_id: seed_id,
      profile_id: profile_id,
      generation_number: attrs.generation_number,
      generation_id: generation_id,
      generation_path: Map.get(attrs, :generation_path),
      is_staged: Map.get(attrs, :is_staged, false),
      pinned: Map.get(attrs, :pinned, false),
      managed: Map.get(attrs, :managed, false),
      is_current: attrs.is_current,
      created_at_generation: attrs.created_at_generation
    }

    case Repo.get_by(__MODULE__,
           garden_id: garden_id,
           profile_id: profile_id,
           generation_id: generation_id
         ) do
      nil ->
        %__MODULE__{}
        |> changeset(changeset_attrs)
        |> Repo.insert()

      %__MODULE__{} = existing ->
        update_attrs = Map.put(changeset_attrs, :updated_at, DateTime.utc_now())

        if generation_row_changed?(existing, update_attrs) do
          existing
          |> changeset(update_attrs)
          |> Repo.update()
        else
          {:ok, existing}
        end
    end
  end

  def update_garden_seed_generations(
        %SowerClient.Orchestration.GardenSeedsReport{} = report,
        %Garden{} = garden
      ) do
    result =
      Repo.transaction(fn ->
        failed_paths = report.failed_profile_paths || []

        for profile <- report.profiles,
            report.complete != false,
            profile.profile_path not in failed_paths do
          unless is_binary(profile.profile_path) and profile.profile_path != "" do
            Repo.rollback(:invalid_profile_path)
          end

          nix_profile = NixProfile.find_or_create!(profile.profile_path)
          rows = resolve_profile_generation_rows(garden, profile)
          sync_profile_generation_rows(garden, nix_profile, rows, report.complete != false)
        end

        if Enum.empty?(report.profiles) and report.complete != false and failed_paths == [] do
          from(g in __MODULE__, where: g.garden_id == ^garden.id and not g.managed)
          |> Repo.delete_all()
        end

        :ok
      end)

    case result do
      {:ok, :ok} ->
        GardenPubSub.broadcast_seed_generations_change(garden, :updated)
        result

      _ ->
        result
    end
  end

  defp resolve_profile_generation_rows(%Garden{} = garden, profile) do
    artifacts =
      profile.generations
      |> Enum.map(& &1.path)
      |> Enum.uniq()

    seeds_by_artifact =
      from(s in Seed, where: s.artifact in ^artifacts)
      |> Repo.all()
      |> Map.new(&{&1.artifact, &1})

    {rows, _seeds_by_artifact} =
      Enum.reduce(profile.generations, {[], seeds_by_artifact}, fn gen, {rows, seeds} ->
        if profile.managed and (is_nil(gen.generation_id) or is_nil(gen.seed_sid)) do
          Repo.rollback(:managed_generation_identity_required)
        end

        explicit_seed =
          if gen.seed_sid do
            case Repo.get_by(Seed, sid: gen.seed_sid) do
              %Seed{artifact: artifact} = seed when artifact == gen.path -> seed
              _ -> Repo.rollback(:generation_seed_mismatch)
            end
          end

        {seed, seeds} =
          case explicit_seed || Map.get(seeds, gen.path) do
            nil ->
              case Seed.find_or_register(garden, gen, profile) do
                {:ok, seed} ->
                  {seed, Map.put(seeds, gen.path, seed)}

                {:error, error} ->
                  Logger.warning(
                    msg: "Failed to auto-register seed from garden",
                    artifact: gen.path,
                    error: error
                  )

                  Repo.rollback({:generation_seed_resolution_failed, error})
              end

            seed ->
              {seed, seeds}
          end

        case {seed, parse_generation_created(gen.created)} do
          {nil, _} ->
            Repo.rollback(:generation_seed_resolution_failed)

          {_, :error} ->
            Logger.warning(
              msg: "Failed to parse generation created timestamp",
              artifact: gen.path,
              created: gen.created
            )

            Repo.rollback(:invalid_generation_timestamp)

          {%Seed{id: seed_id}, {:ok, created_at}} ->
            row = %{
              seed_id: seed_id,
              generation_number: gen.generation_number,
              generation_id:
                gen.generation_id ||
                  if(gen.generation_number,
                    do: "legacy:#{gen.generation_number}",
                    else: "legacy:seed:#{seed_id}"
                  ),
              generation_path: gen.generation_path || gen.link,
              is_staged: gen.is_staged || false,
              pinned: gen.pinned || false,
              managed: profile.managed || false,
              is_current: gen.is_current,
              created_at_generation: created_at
            }

            {[row | rows], seeds}
        end
      end)

    rows
    |> Enum.reverse()
    |> normalize_current_generation_rows()
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.generation_id)
    |> Enum.reverse()
  end

  defp parse_generation_created(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :second)}

  defp parse_generation_created(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  defp parse_generation_created(_), do: :error

  defp normalize_current_generation_rows(rows) do
    current_generation_id =
      Enum.reduce(rows, nil, fn row, acc ->
        if row.is_current, do: row.generation_id, else: acc
      end)

    if is_nil(current_generation_id) do
      rows
    else
      Enum.map(rows, fn row ->
        %{row | is_current: row.generation_id == current_generation_id}
      end)
    end
  end

  defp sync_profile_generation_rows(%Garden{} = garden, nix_profile, rows, complete?) do
    if complete? and Enum.any?(rows, & &1.is_current) do
      from(asg in __MODULE__,
        where: asg.garden_id == ^garden.id and asg.profile_id == ^nix_profile.id
      )
      |> Repo.update_all(set: [is_current: false])
    end

    keep_generation_ids =
      Enum.map(rows, fn row ->
        case upsert_garden_generation(garden.id, nix_profile.id, row.seed_id, row) do
          {:ok, _} -> row.generation_id
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    if complete? do
      delete_stale_garden_seed_generations(garden.id, nix_profile.id, keep_generation_ids)
    end
  end

  defp generation_row_changed?(existing, attrs) do
    Enum.any?(
      [
        :seed_id,
        :generation_number,
        :generation_path,
        :is_current,
        :is_staged,
        :pinned,
        :managed,
        :created_at_generation
      ],
      &(Map.get(existing, &1) != Map.get(attrs, &1))
    )
  end

  defp delete_stale_garden_seed_generations(garden_id, profile_id, keep_generation_ids) do
    query =
      from(asg in __MODULE__,
        where: asg.garden_id == ^garden_id and asg.profile_id == ^profile_id
      )

    query =
      if keep_generation_ids == [] do
        query
      else
        from(asg in query, where: asg.generation_id not in ^keep_generation_ids)
      end

    Repo.delete_all(query)
  end
end
