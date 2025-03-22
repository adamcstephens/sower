defmodule Sower.Nix do
  @moduledoc """
  The Nix context.
  """

  import Ecto.Query, warn: false
  alias Sower.Repo

  alias Sower.Nix.Cache
  alias Sower.Nix.StorePath

  @doc """
  Returns the list of nix_caches.

  ## Examples

      iex> list_nix_caches()
      [%Cache{}, ...]

  """
  def list_nix_caches do
    Repo.all(Cache)
  end

  @doc """
  Gets a single cache.

  Raises `Ecto.NoResultsError` if the Cache does not exist.

  ## Examples

      iex> get_cache!(123)
      %Cache{}

      iex> get_cache!(456)
      ** (Ecto.NoResultsError)

  """
  def get_cache!(id), do: Repo.get!(Cache, id)

  @doc """
  Gets a single cache using sid.

  Raises `Ecto.NoResultsError` if the Cache does not exist.

  ## Examples

      iex> get_cache_sid!(123)
      %Cache{}

      iex> get_cache_sid!(456)
      ** (Ecto.NoResultsError)

  """
  def get_cache_sid!(sid), do: Repo.get_by!(Cache, sid: sid)

  @doc """
  Creates a cache.

  ## Examples

      iex> create_cache(%{field: value})
      {:ok, %Cache{}}

      iex> create_cache(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_cache(attrs \\ %{}) do
    %Cache{
      org_id: Sower.Repo.get_org_id()
    }
    |> Cache.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a cache.

  ## Examples

      iex> update_cache(cache, %{field: new_value})
      {:ok, %Cache{}}

      iex> update_cache(cache, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_cache(%Cache{} = cache, attrs) do
    cache
    |> Cache.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a cache.

  ## Examples

      iex> delete_cache(cache)
      {:ok, %Cache{}}

      iex> delete_cache(cache)
      {:error, %Ecto.Changeset{}}

  """
  def delete_cache(%Cache{} = cache) do
    Repo.delete(cache)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking cache changes.

  ## Examples

      iex> change_cache(cache)
      %Ecto.Changeset{data: %Cache{}}

  """
  def change_cache(%Cache{} = cache, attrs \\ %{}) do
    Cache.changeset(cache, attrs)
  end

  @doc """
  Returns the list of store_paths.

  ## Examples

      iex> list_store_paths()
      [%StorePath{}, ...]

  """
  def list_store_paths do
    Repo.all(StorePath)
  end

  @doc """
  Gets a single store_path.

  Raises `Ecto.NoResultsError` if the Store path does not exist.

  ## Examples

      iex> get_store_path!(123)
      %StorePath{}

      iex> get_store_path!(456)
      ** (Ecto.NoResultsError)

  """
  def get_store_path!(id), do: Repo.get!(StorePath, id)

  @doc """
  Gets a single store_path using digeste.

  Raises `Ecto.NoResultsError` if the Store path does not exist.

  ## Examples

      iex> get_store_path_digest!(123)
      %StorePath{}

      iex> get_store_path_digest!(456)
      ** (Ecto.NoResultsError)

  """
  def get_store_path_digest!(digest), do: Repo.get_by!(StorePath, path_digest: digest)

  @doc """
  Creates a store_path.

  ## Examples

      iex> create_store_path(%{field: value})
      {:ok, %StorePath{}}

      iex> create_store_path(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_store_path(attrs \\ %{}) do
    %StorePath{}
    |> StorePath.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a store_path.

  ## Examples

      iex> update_store_path(store_path, %{field: new_value})
      {:ok, %StorePath{}}

      iex> update_store_path(store_path, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_store_path(%StorePath{} = store_path, attrs) do
    store_path
    |> StorePath.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a store_path.

  ## Examples

      iex> delete_store_path(store_path)
      {:ok, %StorePath{}}

      iex> delete_store_path(store_path)
      {:error, %Ecto.Changeset{}}

  """
  def delete_store_path(%StorePath{} = store_path) do
    Repo.delete(store_path)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking store_path changes.

  ## Examples

      iex> change_store_path(store_path)
      %Ecto.Changeset{data: %StorePath{}}

  """
  def change_store_path(%StorePath{} = store_path, attrs \\ %{}) do
    StorePath.changeset(store_path, attrs)
  end

  @doc """
  Submit a full store path, updating timestamp on resubmit
  """
  def submit_store_path!(%{path: _path} = attrs) do
    %StorePath{
      org_id: Sower.Repo.get_org_id()
    }
    |> StorePath.changeset(attrs)
    |> Sower.Repo.insert!(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:path, :org_id],
      returning: true
    )
  end

  # Submit a full store path with only a path
  def submit_store_path!(path) when is_binary(path) do
    submit_store_path!(%{path: path})
  end

  @doc """
  Get a store path by path
  """
  def get_store_path_by_path!(path) when is_binary(path) do
    Sower.Repo.get_by!(StorePath, path: path)
  end
end
