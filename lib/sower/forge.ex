defmodule Sower.Forge do
  @moduledoc """
  The Forge context.
  """

  import Ecto.Query, warn: false
  alias Sower.Repo

  alias Sower.Forge.Hook

  @doc """
  Returns the list of hooks.

  ## Examples

      iex> list_hooks()
      [%Hook{}, ...]

  """
  def list_hooks do
    Repo.all(Hook)
  end

  @doc """
  Gets a single hook.

  Raises `Ecto.NoResultsError` if the Hook does not exist.

  ## Examples

      iex> get_hook!(123)
      %Hook{}

      iex> get_hook!(456)
      ** (Ecto.NoResultsError)

  """
  def get_hook!(id), do: Repo.get!(Hook, id)

  @doc """
  Creates a hook.

  ## Examples

      iex> create_hook(%{field: value})
      {:ok, %Hook{}}

      iex> create_hook(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_hook(attrs \\ %{}) do
    %Hook{}
    |> Hook.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a hook.

  ## Examples

      iex> update_hook(hook, %{field: new_value})
      {:ok, %Hook{}}

      iex> update_hook(hook, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_hook(%Hook{} = hook, attrs) do
    hook
    |> Hook.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a hook.

  ## Examples

      iex> delete_hook(hook)
      {:ok, %Hook{}}

      iex> delete_hook(hook)
      {:error, %Ecto.Changeset{}}

  """
  def delete_hook(%Hook{} = hook) do
    Repo.delete(hook)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking hook changes.

  ## Examples

      iex> change_hook(hook)
      %Ecto.Changeset{data: %Hook{}}

  """
  def change_hook(%Hook{} = hook, attrs \\ %{}) do
    Hook.changeset(hook, attrs)
  end

  alias Sower.Forge.Repository

  @doc """
  Returns the list of repositories.

  ## Examples

      iex> list_repositories()
      [%Repository{}, ...]

  """
  def list_repositories do
    Repo.all(Repository)
  end

  @doc """
  Gets a single repository.

  Raises `Ecto.NoResultsError` if the Repository does not exist.

  ## Examples

      iex> get_repository!(123)
      %Repository{}

      iex> get_repository!(456)
      ** (Ecto.NoResultsError)

  """
  def get_repository!(id), do: Repo.get!(Repository, id)

  @doc """
  Creates a repository.

  ## Examples

      iex> create_repository(%{field: value})
      {:ok, %Repository{}}

      iex> create_repository(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_repository(attrs \\ %{}) do
    %Repository{}
    |> Repository.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a repository.

  ## Examples

      iex> update_repository(repository, %{field: new_value})
      {:ok, %Repository{}}

      iex> update_repository(repository, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_repository(%Repository{} = repository, attrs) do
    repository
    |> Repository.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a repository.

  ## Examples

      iex> delete_repository(repository)
      {:ok, %Repository{}}

      iex> delete_repository(repository)
      {:error, %Ecto.Changeset{}}

  """
  def delete_repository(%Repository{} = repository) do
    Repo.delete(repository)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking repository changes.

  ## Examples

      iex> change_repository(repository)
      %Ecto.Changeset{data: %Repository{}}

  """
  def change_repository(%Repository{} = repository, attrs \\ %{}) do
    Repository.changeset(repository, attrs)
  end

  def clone_repository(%Repository{} = repository) do
    Map.get(repository, :url) |> Git.Git.clone()
  end
end
