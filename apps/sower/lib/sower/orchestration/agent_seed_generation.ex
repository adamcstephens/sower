defmodule Sower.Orchestration.AgentSeedGeneration do
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Sower.Repo
  alias Sower.Orchestration.{Agent, NixProfile, Seed}

  require Logger

  schema "agent_seed_generations" do
    field :org_id, Ecto.UUID

    belongs_to :agent, Agent
    belongs_to :seed, Seed
    belongs_to :profile, NixProfile

    field :generation_number, :integer
    field :is_current, :boolean, default: false
    field :created_at_generation, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = agent_seed_generation, attrs) do
    agent_seed_generation
    |> cast(attrs, [
      :org_id,
      :agent_id,
      :seed_id,
      :profile_id,
      :generation_number,
      :is_current,
      :created_at_generation
    ])
    |> validate_required([:org_id, :agent_id, :seed_id, :profile_id, :created_at_generation])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:seed_id)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:agent_id, :seed_id])
  end

  def list_agent_seed_generation(%Agent{id: agent_id}) do
    from(asg in __MODULE__,
      where: asg.agent_id == ^agent_id,
      order_by: [desc: asg.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  def list_current_seed_generation(%Agent{id: agent_id}) do
    from(asg in __MODULE__,
      where: asg.agent_id == ^agent_id and asg.is_current == true,
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  def list_agent_seed_generation_profile(agent_id, profile_id) do
    from(asg in __MODULE__,
      where: asg.agent_id == ^agent_id and asg.profile_id == ^profile_id,
      order_by: [desc: asg.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  def upsert_agent_generation(agent_id, profile_id, seed_id, attrs) do
    now = DateTime.utc_now()

    changeset_attrs = %{
      org_id: Repo.get_org_id(),
      agent_id: agent_id,
      seed_id: seed_id,
      profile_id: profile_id,
      generation_number: attrs.generation_number,
      is_current: attrs.is_current,
      created_at_generation: attrs.created_at_generation
    }

    case Repo.get_by(__MODULE__, agent_id: agent_id, seed_id: seed_id) do
      nil ->
        %__MODULE__{}
        |> changeset(changeset_attrs)
        |> Repo.insert()

      %__MODULE__{} = existing ->
        update_attrs = %{
          profile_id: profile_id,
          generation_number: attrs.generation_number,
          is_current: attrs.is_current,
          created_at_generation: attrs.created_at_generation,
          updated_at: now
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

  def update_agent_seed_generations(
        %SowerClient.Orchestration.AgentSeedsReport{} = report,
        %Agent{} = agent
      ) do
    Repo.transaction(fn ->
      if Enum.empty?(report.profiles) do
        delete_all_agent_seed_generations(agent.id)
      else
        for profile <- report.profiles do
          nix_profile = NixProfile.find_or_create!(profile.profile_path)
          rows = resolve_profile_generation_rows(agent, profile)
          sync_profile_generation_rows(agent, nix_profile, rows)
        end
      end

      :ok
    end)
  end

  defp resolve_profile_generation_rows(%Agent{} = agent, profile) do
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
        {seed, seeds} =
          case Map.get(seeds, gen.path) do
            nil ->
              case Seed.find_or_register(agent, gen, profile) do
                {:ok, seed} ->
                  {seed, Map.put(seeds, gen.path, seed)}

                {:error, error} ->
                  Logger.warning(
                    msg: "Failed to auto-register seed from agent",
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
    |> Enum.uniq_by(& &1.seed_id)
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
    current_seed_id =
      Enum.reduce(rows, nil, fn row, acc -> if row.is_current, do: row.seed_id, else: acc end)

    if is_nil(current_seed_id) do
      rows
    else
      Enum.map(rows, fn row ->
        %{row | is_current: row.seed_id == current_seed_id}
      end)
    end
  end

  defp sync_profile_generation_rows(%Agent{} = agent, nix_profile, rows) do
    if Enum.any?(rows, & &1.is_current) do
      from(asg in __MODULE__,
        where: asg.agent_id == ^agent.id and asg.profile_id == ^nix_profile.id
      )
      |> Repo.update_all(set: [is_current: false])
    end

    keep_seed_ids =
      Enum.reduce(rows, [], fn row, acc ->
        upsert_agent_generation(agent.id, nix_profile.id, row.seed_id, row)
        [row.seed_id | acc]
      end)
      |> Enum.uniq()

    delete_stale_agent_seed_generations(agent.id, nix_profile.id, keep_seed_ids)
  end

  defp generation_row_changed?(existing, attrs) do
    existing.profile_id != attrs.profile_id or
      existing.generation_number != attrs.generation_number or
      existing.is_current != attrs.is_current or
      existing.created_at_generation != attrs.created_at_generation
  end

  defp delete_stale_agent_seed_generations(agent_id, profile_id, keep_seed_ids) do
    query =
      from(asg in __MODULE__,
        where: asg.agent_id == ^agent_id and asg.profile_id == ^profile_id
      )

    query =
      if keep_seed_ids == [] do
        query
      else
        from(asg in query, where: asg.seed_id not in ^keep_seed_ids)
      end

    Repo.delete_all(query)
  end

  defp delete_all_agent_seed_generations(agent_id) do
    from(asg in __MODULE__, where: asg.agent_id == ^agent_id)
    |> Repo.delete_all()
  end
end
