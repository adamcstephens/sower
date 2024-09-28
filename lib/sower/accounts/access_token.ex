defmodule Sower.Accounts.AccessToken do
  use Sower.Schema

  alias Sower.Accounts.AccessToken
  alias Sower.Repo

  import Ecto.Changeset

  require Logger

  schema "access_tokens" do
    field :expires_at, :date
    field :description, :string

    belongs_to(:user, Sower.Accounts.User)

    timestamps()
  end

  def changeset(access_token, attrs \\ %{}) do
    access_token
    |> cast(attrs, [:expires_at, :user_id, :description])
    |> validate_required([:expires_at, :user_id, :description])
  end

  def create(%AccessToken{} = access_token, %{"expires_at" => _} = attrs) do
    access_token
    |> changeset(attrs)
    |> Repo.insert()
    |> generate_token()
  end

  def create(%{"expires_at" => _} = attrs) do
    create(%AccessToken{}, attrs)
  end

  def create(attrs) do
    default_expiration = Date.utc_today() |> Date.add(1)

    create(attrs |> Map.put("expires_at", default_expiration))
  end

  defp generate_token({:ok, access_token}) do
    {:ok, expire} =
      access_token.expires_at
      |> DateTime.new(Time.new!(0, 0, 0))

    expire =
      expire
      |> DateTime.diff(DateTime.utc_now())

    token =
      "sower_" <>
        Phoenix.Token.encrypt(
          SowerWeb.Endpoint,
          "access-token",
          "#{access_token.id}:#{access_token.user_id}",
          max_age: expire
        )

    # todo, return token for display
    {:ok, access_token, token}
  end

  defp generate_token({:error, changeset}) do
    {:error, changeset}
  end

  def update(%AccessToken{} = access_token, %{"expires_at" => _} = attrs) do
    access_token
    |> changeset(attrs)
    |> Repo.update()
    |> generate_token()
  end

  def authenticate(token) do
    with "sower_" <> token <- token,
         {:ok, decrypted} <-
           Phoenix.Token.decrypt(SowerWeb.Endpoint, "access-token", token),
         [access_token_id, user_id] = String.split(decrypted, ":"),
         access_token <- Repo.get(AccessToken, access_token_id),
         true <- access_token.user_id == user_id do
      {:ok, Sower.Accounts.User.get_by_id!(user_id)}
    else
      _ ->
        Logger.error("Invalid token")
        {:error, "Invalid token"}
    end

    # Repo.one(from(a in AccessToken, where: a.id == ^access_token_id and a.user_id == ^user_id))
  end

  def delete(access_token) do
    Repo.delete(access_token)
  end

  def get!(id) do
    AccessToken |> Sower.Repo.get!(id)
  end

  def list() do
    AccessToken |> Sower.Repo.all()
  end
end
