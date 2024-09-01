defmodule Sower.Accounts.User do
  use Sower.Schema

  import Ecto.Changeset

  alias Sower.Accounts.{User, UserToken}
  alias Sower.Repo

  @primary_key {:id, UUIDv7, autogenerate: true}

  schema "users" do
    field :email, :string
    field :name, :string
    field :oidc_id, Ecto.UUID

    timestamps()
  end

  # TODO upsert attrs to sync from OIDC provider
  def find_or_create(oidc_id, attrs) do
    case Repo.get_by(User, oidc_id: oidc_id) do
      nil ->
        %User{oidc_id: oidc_id}
        |> changeset(%{oidc_id: oidc_id} |> Map.merge(attrs))
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  def get_by_id!(id) do
    Repo.get!(User, id)
  end

  def new(attrs) do
    %User{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  defp changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :oidc_id])
    |> validate_required([:oidc_id])
    |> validate_email()
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end
end
