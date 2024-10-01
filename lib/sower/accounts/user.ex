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
    field :org_id, Ecto.UUID

    timestamps()
  end

  def get_by_id!(id) do
    Repo.get!(User, id, skip_org_id: true)
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
    Repo.insert!(user_token, skip_org_id: true)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query, skip_org_id: true)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"), skip_org_id: true)
    :ok
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :oidc_id, :org_id])
    |> validate_required([:oidc_id, :org_id])
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
