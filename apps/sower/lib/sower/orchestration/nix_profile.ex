defmodule Sower.Orchestration.NixProfile do
  use Sower.Schema
  import Ecto.Changeset

  alias Sower.Repo

  schema "nix_profiles" do
    field :profile_path, :string

    has_many :agent_seed_generations, Sower.Orchestration.AgentSeedGeneration,
      foreign_key: :profile_id

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = nix_profile, attrs) do
    nix_profile
    |> cast(attrs, [:profile_path])
    |> validate_required([:profile_path])
    |> unique_constraint([:profile_path])
  end

  @doc """
  Finds an existing NixProfile by path, or creates one if it doesn't exist.

  NixProfile is a global lookup table - profile paths are the same across all orgs.
  Uses skip_org_id to bypass org-scoped queries.

  Returns `{:ok, nix_profile}` on success, or `{:error, changeset}` on failure.
  """
  def find_or_create(profile_path) do
    case Repo.get_by(__MODULE__, [profile_path: profile_path], skip_org_id: true) do
      nil ->
        %__MODULE__{}
        |> changeset(%{profile_path: profile_path})
        |> Repo.insert(skip_org_id: true)

      nix_profile ->
        {:ok, nix_profile}
    end
  end

  @doc """
  Same as `find_or_create/1` but raises on error.
  """
  def find_or_create!(profile_path) do
    case find_or_create(profile_path) do
      {:ok, nix_profile} -> nix_profile
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
    end
  end

  @doc """
  Gets a NixProfile by path, or returns nil if not found.
  """
  def get_by_path(profile_path) do
    Repo.get_by(__MODULE__, [profile_path: profile_path], skip_org_id: true)
  end
end
