defmodule Sower.Orchestration.GardenSeedGeneration do
  @moduledoc "Reconciles observed native generations by garden, profile and generation number."
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
      :is_current,
      :created_at_generation
    ])
    |> validate_required([:org_id, :garden_id, :seed_id, :profile_id, :created_at_generation])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:garden_id)
    |> foreign_key_constraint(:seed_id)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:garden_id, :profile_id, :generation_number],
      name: :garden_profile_generation_identity_index
    )
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
    changeset_attrs = %{
      org_id: Repo.get_org_id(),
      garden_id: garden_id,
      seed_id: seed_id,
      profile_id: profile_id,
      generation_number: attrs.generation_number,
      is_current: attrs.is_current,
      created_at_generation: attrs.created_at_generation
    }

    query =
      from(g in __MODULE__, where: g.garden_id == ^garden_id and g.profile_id == ^profile_id)

    query =
      if attrs.generation_number == nil,
        do: from(g in query, where: is_nil(g.generation_number) and g.seed_id == ^seed_id),
        else: from(g in query, where: g.generation_number == ^attrs.generation_number)

    case Repo.one(query) do
      nil ->
        %__MODULE__{}
        |> changeset(changeset_attrs)
        |> Repo.insert()

      %__MODULE__{} = existing ->
        update_attrs = %{
          seed_id: seed_id,
          profile_id: profile_id,
          generation_number: attrs.generation_number,
          is_current: attrs.is_current,
          created_at_generation: attrs.created_at_generation,
          updated_at: DateTime.utc_now()
        }

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
        if report.complete != false do
          profile_ids =
            for profile <- report.profiles do
              nix_profile = NixProfile.find_or_create!(profile.profile_path)
              rows = resolve_profile_generation_rows(garden, profile)
              sync_profile_generation_rows(garden, nix_profile, rows)
              nix_profile.id
            end

          from(g in __MODULE__,
            where: g.garden_id == ^garden.id and g.profile_id not in ^profile_ids
          )
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

    query = from(s in Seed, where: s.artifact in ^artifacts)

    query =
      if profile.seed_type,
        do: from(s in query, where: s.seed_type == ^profile.seed_type),
        else: query

    seeds_by_artifact =
      query
      |> Repo.all()
      |> Map.new(&{&1.artifact, &1})

    {rows, _seeds_by_artifact} =
      Enum.reduce(profile.generations, {[], seeds_by_artifact}, fn gen, {rows, seeds} ->
        {seed, seeds} =
          case Map.get(seeds, gen.path) do
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

                  {nil, seeds}
              end

            seed ->
              {seed, seeds}
          end

        case {seed, parse_generation_created(gen.created)} do
          {nil, _} ->
            {rows, seeds}

          {_, :error} ->
            Logger.warning(
              msg: "Failed to parse generation created timestamp",
              artifact: gen.path,
              created: gen.created
            )

            {rows, seeds}

          {%Seed{id: seed_id}, {:ok, created_at}} ->
            row = %{
              seed_id: seed_id,
              generation_number: gen.generation_number,
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
    |> Enum.uniq_by(&generation_identity/1)
    |> Enum.reverse()
  end

  defp generation_identity(row), do: row.generation_number || {:seed, row.seed_id}

  defp parse_generation_created(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :second)}

  defp parse_generation_created(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  defp parse_generation_created(_), do: :error

  defp normalize_current_generation_rows(rows) do
    current_number =
      Enum.reduce(rows, nil, fn row, acc ->
        if row.is_current, do: generation_identity(row), else: acc
      end)

    if is_nil(current_number) do
      rows
    else
      Enum.map(rows, fn row ->
        %{row | is_current: generation_identity(row) == current_number}
      end)
    end
  end

  defp sync_profile_generation_rows(%Garden{} = garden, nix_profile, rows) do
    if Enum.any?(rows, & &1.is_current) do
      from(asg in __MODULE__,
        where: asg.garden_id == ^garden.id and asg.profile_id == ^nix_profile.id
      )
      |> Repo.update_all(set: [is_current: false])
    end

    keep_ids =
      Enum.map(rows, fn row ->
        {:ok, generation} = upsert_garden_generation(garden.id, nix_profile.id, row.seed_id, row)
        generation.id
      end)

    delete_stale_garden_seed_generations(garden.id, nix_profile.id, keep_ids)
  end

  defp generation_row_changed?(existing, attrs) do
    existing.seed_id != attrs.seed_id or existing.profile_id != attrs.profile_id or
      existing.generation_number != attrs.generation_number or
      existing.is_current != attrs.is_current or
      existing.created_at_generation != attrs.created_at_generation
  end

  defp delete_stale_garden_seed_generations(garden_id, profile_id, keep_ids) do
    query =
      from(asg in __MODULE__,
        where: asg.garden_id == ^garden_id and asg.profile_id == ^profile_id
      )

    query =
      if keep_ids == [] do
        query
      else
        from(asg in query, where: asg.id not in ^keep_ids)
      end

    Repo.delete_all(query)
  end
end
