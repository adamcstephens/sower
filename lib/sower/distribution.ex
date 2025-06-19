defmodule Sower.Distribution do
  @moduledoc """
  The Distribution context.
  """

  import Ecto.Query, warn: false
  alias Sower.Repo

  alias Sower.Distribution.Deployment

  @doc """
  Returns the list of deployments.

  ## Examples

      iex> list_deployments()
      [%Deployment{}, ...]

  """
  def list_deployments do
    Repo.all(Deployment)
  end

  @doc """
  Gets a single deployment.

  Raises `Ecto.NoResultsError` if the Deployment does not exist.

  ## Examples

      iex> get_deployment!(123)
      %Deployment{}

      iex> get_deployment!(456)
      ** (Ecto.NoResultsError)

  """
  def get_deployment!(id), do: Repo.get!(Deployment, id)

  @doc """
  Creates a deployment.

  ## Examples

      iex> create_deployment(%{field: value})
      {:ok, %Deployment{}}

      iex> create_deployment(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_deployment(attrs \\ %{}) do
    %Deployment{
      org_id: Sower.Repo.get_org_id()
    }
    |> Deployment.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a deployment.

  ## Examples

      iex> update_deployment(deployment, %{field: new_value})
      {:ok, %Deployment{}}

      iex> update_deployment(deployment, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_deployment(%Deployment{} = deployment, attrs) do
    deployment
    |> Deployment.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a deployment.

  ## Examples

      iex> delete_deployment(deployment)
      {:ok, %Deployment{}}

      iex> delete_deployment(deployment)
      {:error, %Ecto.Changeset{}}

  """
  def delete_deployment(%Deployment{} = deployment) do
    Repo.delete(deployment)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking deployment changes.

  ## Examples

      iex> change_deployment(deployment)
      %Ecto.Changeset{data: %Deployment{}}

  """
  def change_deployment(%Deployment{} = deployment, attrs \\ %{}) do
    Deployment.changeset(deployment, attrs)
  end
end
