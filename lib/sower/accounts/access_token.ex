defmodule Sower.Accounts.AccessToken do
  use Sower.Schema

  alias Ecto.Changeset
  alias Sower.Accounts.AccessToken
  alias Sower.Repo

  import Ecto.Changeset

  require Logger

  schema "access_tokens" do
    field :expires_at, :date
    field :description, :string
    field :regenerate, :boolean, virtual: true
    field :token, :string, virtual: true

    belongs_to :user, Sower.Accounts.User

    embeds_many :permissions, Permission, on_replace: :delete do
      field :action, Ecto.Enum, values: [:read, :update]
      field :resource, Ecto.Enum, values: [Sower.Seed]
    end

    timestamps()
  end

  def changeset(access_token, attrs \\ %{}) do
    access_token
    |> cast(attrs, [:expires_at, :user_id, :description, :regenerate])
    |> validate_required([:expires_at, :user_id, :description])
    |> force_expires_at_regeneration()
    |> cast_embed(:permissions, required: false, with: &changeset_permission/2)
  end

  def changeset_permission(permission, attrs \\ %{}) do
    permission
    |> cast(attrs, [:action, :resource])
    |> validate_required([:action, :resource])
  end

  def create(%AccessToken{} = access_token, %{"expires_at" => _} = attrs) do
    access_token
    |> changeset(attrs)
    |> regenerate_token()
    |> Repo.insert(skip_org_id: true)
  end

  def create(%{"expires_at" => _} = attrs) do
    create(%AccessToken{}, attrs)
  end

  def create(attrs) do
    default_expiration = Date.utc_today() |> Date.add(1)

    create(attrs |> Map.put("expires_at", default_expiration))
  end

  def create() do
    create(%{})
  end

  defp regenerate_token(%Changeset{} = changeset) do
    case get_field(changeset, :regenerate) do
      false ->
        changeset

      _ ->
        {:ok, expire} =
          get_field(changeset, :expires_at)
          |> DateTime.new(Time.new!(0, 0, 0))

        expire =
          expire
          |> DateTime.diff(DateTime.utc_now())

        token =
          "sower_" <>
            Phoenix.Token.encrypt(
              SowerWeb.Endpoint,
              "access-token",
              "#{get_field(changeset, :id)}:#{get_field(changeset, :user_id)}",
              max_age: expire
            )

        changeset |> put_change(:token, token)
    end
  end

  def update(%AccessToken{} = access_token, attrs) do
    access_token
    |> changeset(attrs)
    |> regenerate_token()
    |> Repo.update(skip_org_id: true)
  end

  def authenticate(token) do
    with "sower_" <> token <- token,
         {:ok, decrypted} <-
           Phoenix.Token.decrypt(SowerWeb.Endpoint, "access-token", token),
         [access_token_id, user_id] = String.split(decrypted, ":"),
         access_token <- Repo.get(AccessToken, access_token_id, skip_org_id: true),
         true <- access_token.user_id == user_id do
      {:ok, Sower.Accounts.User.get_by_id!(user_id)}
    else
      _ ->
        Logger.error("Invalid token")
        {:error, "Invalid token"}
    end

    # Repo.one(from(a in AccessToken, where: a.id == ^access_token_id and a.user_id == ^user_id))
  end

  defp force_expires_at_regeneration(%Changeset{} = changeset) do
    case get_change(changeset, :expires_at) do
      nil ->
        changeset

      expires_at ->
        if expires_at != changeset.data.expires_at do
          put_change(changeset, :regenerate, true)
        else
          changeset
        end
    end
  end

  def delete(access_token) do
    Repo.delete(access_token, skip_org_id: true)
  end

  def get!(id) do
    AccessToken |> Sower.Repo.get!(id, skip_org_id: true)
  end

  def list() do
    AccessToken |> Sower.Repo.all(skip_org_id: true)
  end

  def permission_actions() do
    Ecto.Enum.dump_values(Sower.Accounts.AccessToken.Permission, :action)
  end

  def permission_resources() do
    Ecto.Enum.dump_values(Sower.Accounts.AccessToken.Permission, :resource)
  end
end
