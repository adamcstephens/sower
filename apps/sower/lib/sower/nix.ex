defmodule Sower.Nix do
  @moduledoc """
  The Nix context.
  """

  import Ecto.Query, warn: false
  alias Sower.Repo

  alias Sower.Nix.Cache

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
  Gets a single cache using sid.

  Returns `nil` if the Cache does not exist.

  ## Examples

      iex> get_cache_sid("abc123")
      %Cache{}

      iex> get_cache_sid("nonexistent")
      nil

  """
  def get_cache_sid(sid), do: Repo.get_by(Cache, sid: sid)

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
end
