defmodule Sower.Forge do
  @moduledoc """
  The Forge context.
  """

  import Ecto.Query, warn: false
  alias Sower.Accounts
  alias Sower.Repo

  alias Sower.Forge.Connection

  @doc """
  Returns the list of forges.

  ## Examples

      iex> list_forges()
      [%Connection{}, ...]

  """
  def list_forges do
    Repo.all(Connection)
  end

  @doc """
  Gets a single connection.

  Raises `Ecto.NoResultsError` if the Connection does not exist.

  ## Examples

      iex> get_connection!(123)
      %Connection{}

      iex> get_connection!(456)
      ** (Ecto.NoResultsError)

  """
  def get_connection!(id), do: Repo.get!(Connection, id)

  @doc """
  Gets a single connection by sid.

  Raises `Ecto.NoResultsError` if the Connection does not exist.

  ## Examples

      iex> get_connection_sid!(123)
      %Connection{}

      iex> get_connection_sid!(456)
      ** (Ecto.NoResultsError)

  """
  def get_connection_sid!(sid), do: Repo.get_by!(Connection, sid: sid)

  @doc """
  Gets a single connection ignoring organization.

  Raises `Ecto.NoResultsError` if the Connection does not exist.

  ## Examples

      iex> get_global_connection!(123)
      %Connection{}

      iex> get_global_connection!(456)
      ** (Ecto.NoResultsError)

  """
  def get_global_connection!(id), do: Repo.get!(Connection, id, skip_org_id: true)

  @doc """
  Gets a single connection by sid ignoring organization.

  Raises `Ecto.NoResultsError` if the Connection does not exist.

  ## Examples

      iex> get_global_connection_sid!(123)
      %Connection{}

      iex> get_global_connection_sid!(456)
      ** (Ecto.NoResultsError)

  """
  def get_global_connection_sid!(sid), do: Repo.get_by!(Connection, [sid: sid], skip_org_id: true)

  @doc """
  Creates a connection.

  ## Examples

      iex> create_connection(%{field: value})
      {:ok, %Connection{}}

      iex> create_connection(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_connection(attrs \\ %{}) do
    %Connection{
      org_id: Sower.Repo.get_org_id()
    }
    |> Connection.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a connection.

  ## Examples

      iex> update_connection(connection, %{field: new_value})
      {:ok, %Connection{}}

      iex> update_connection(connection, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_connection(%Connection{} = connection, attrs) do
    connection
    |> Connection.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a connection.

  ## Examples

      iex> delete_connection(connection)
      {:ok, %Connection{}}

      iex> delete_connection(connection)
      {:error, %Ecto.Changeset{}}

  """
  def delete_connection(%Connection{} = connection) do
    Repo.delete(connection)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking connection changes.

  ## Examples

      iex> change_connection(connection)
      %Ecto.Changeset{data: %Connection{}}

  """
  def change_connection(%Connection{} = connection, attrs \\ %{}) do
    Connection.changeset(connection, attrs)
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
  Returns the list of repository fullnames (owner/.

  ## Examples

      iex> list_repositories()
      [%Repository{}, ...]

  """
  def list_forge_repositories_fullnames(%Connection{} = forge) do
    query =
      from r in Repository,
        select: fragment("concat(?, '/', ?)", r.owner, r.repo),
        where: r.forge_id == ^forge.id

    Repo.all(query)
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
  Gets a single repository ignoring organization.

  Raises `Ecto.NoResultsError` if the Repository does not exist.

  ## Examples

      iex> get_global_repository!(123)
      %Repository{}

      iex> get_global_repository!(456)
      ** (Ecto.NoResultsError)

  """
  def get_global_repository!(id), do: Repo.get!(Repository, id, skip_org_id: true)

  @doc """
  Gets a single repository by sid ignoring organization.

  Raises `Ecto.NoResultsError` if the Repository does not exist.

  ## Examples

      iex> get_global_repository_sid!(123)
      %Repository{}

      iex> get_global_repository_sid!(456)
      ** (Ecto.NoResultsError)

  """
  def get_global_repository_sid!(sid), do: Repo.get_by!(Repository, [sid: sid], skip_org_id: true)

  @doc """
  Creates a repository.

  ## Examples

      iex> create_repository(%{field: value})
      {:ok, %Repository{}}

      iex> create_repository(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_repository(attrs \\ %{}) do
    %Repository{
      org_id: Sower.Repo.get_org_id(),
      webhook_secret: 64 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    }
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

  def register_repository_webhook(%Repository{} = repository, access_token) do
    repository = repository |> Sower.Repo.preload(:forge)

    Sower.Forge.ClientApi.new(repository.forge, access_token)
    |> Sower.Forge.ClientApi.register_repo_webhook(repository)
  end

  def deregister_repository_webhook(%Repository{} = repository, access_token) do
    repository = repository |> Sower.Repo.preload(:forge)

    Sower.Forge.ClientApi.new(repository.forge, access_token)
    |> Sower.Forge.ClientApi.deregister_repo_webhook(repository)
  end

  def add_forge_repository(
        %Connection{} = forge,
        %{"owner" => %{"login" => owner}, "name" => repo, "url" => url},
        access_token
      ) do
    case create_repository(%{
           forge_id: forge.id,
           owner: owner,
           repo: repo,
           url: url
         }) do
      {:ok, repo} ->
        {:ok, %{"id" => hook_id}} =
          register_repository_webhook(repo, access_token)

        update_repository(repo, %{webhook_id: Integer.to_string(hook_id)})

      err ->
        err
    end
  end

  def remove_forge_repository(
        %Connection{} = forge,
        %Repository{} = repo,
        access_token
      ) do
    deregister_repository_webhook(repo, access_token)
    delete_repository(repo)
  end
end
