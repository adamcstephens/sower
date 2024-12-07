defmodule Sower.Accounts.AccessToken do
  use Sower.Schema

  alias Ecto.Changeset
  alias Sower.Accounts.AccessToken
  alias Sower.Repo

  import Ecto.Changeset
  import Ecto.Query

  require Logger

  schema "access_tokens" do
    field :expires_at, :date
    field :description, :string
    field :regenerate, :boolean, virtual: true
    field :token, :string, virtual: true
    field :token_preview, :string, virtual: true
    field :token_hash, :string
    field :org_id, Ecto.UUID

    belongs_to :user, Sower.Accounts.User

    embeds_many :permissions, Permission, on_replace: :delete do
      field :role, Ecto.Enum, values: [:"seed:read", :"seed:write"]
    end

    timestamps()
  end

  def changeset(access_token, attrs \\ %{}) do
    access_token
    |> cast(attrs, [:expires_at, :user_id, :org_id, :description, :regenerate])
    |> validate_required([:expires_at, :user_id, :org_id, :description])
    |> validate_expires_at()
    |> force_expires_at_regeneration()
    |> cast_embed(:permissions,
      required: false,
      with: &changeset_permission/2,
      sort_param: :permissions_sort,
      drop_param: :permissions_drop
    )
  end

  def changeset_permission(permission, attrs \\ %{}) do
    permission
    |> cast(attrs, [:role])
    |> validate_required([:role])
  end

  def validate_expires_at(changeset) do
    validate_change(changeset, :expires_at, fn field, value ->
      {:ok, expire} =
        value
        |> DateTime.new(Time.new!(0, 0, 0), "Etc/UTC")

      if DateTime.before?(expire, DateTime.utc_now()) do
        [{field, "must be at least 24 hours"}]
      else
        []
      end
    end)
  end

  defp put_preview(%AccessToken{} = access_token) do
    preview = "sower_" <> String.slice(ShortUUID.encode!(access_token.id), 0, 8)
    access_token |> Map.put(:token_preview, preview)
  end

  defp put_preview({:ok, %AccessToken{} = access_token}) do
    {:ok, put_preview(access_token)}
  end

  def create(%AccessToken{} = access_token, %{"expires_at" => _} = attrs) do
    access_token
    |> changeset(attrs)
    |> put_change(:regenerate, true)
    |> generate_token()
    |> Repo.insert()
    |> put_preview()
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

  defp generate_token(%Changeset{} = changeset) do
    case get_field(changeset, :regenerate) do
      false ->
        changeset

      _ ->
        id =
          case get_field(changeset, :id) do
            nil ->
              UUIDv7.generate()

            id ->
              id
          end

        short_id = ShortUUID.encode!(id)
        rand = :crypto.strong_rand_bytes(48) |> Base.encode64()
        {:ok, hash} = :argon2.hash(rand)

        token = "sower_" <> short_id <> "_" <> rand

        changeset
        |> put_change(:id, id)
        |> put_change(:token, token)
        |> put_change(:token_hash, hash)
    end
  end

  def split_token(token) do
    case String.split(token, "_") do
      ["sower", id, rand] ->
        {:ok, id, rand}

      _ ->
        {:error, "invalid token"}
    end
  end

  def update(%AccessToken{} = access_token, attrs) do
    access_token
    |> changeset(attrs)
    |> generate_token()
    |> Repo.update()
    |> put_preview()
  end

  def authenticate(token) do
    with {:ok, short_id, rand} <- split_token(token),
         {:ok, id} <- ShortUUID.decode(short_id),
         access_token when not is_nil(access_token) <- get(id),
         true <- verify_not_expired(access_token),
         {:ok, true} <- :argon2.verify(rand, access_token.token_hash) do
      {:ok, access_token |> Sower.Repo.preload(:user)}
    else
      {:ok, false} ->
        {:error, "Invalid token: Verification failed"}

      {:error, _} = error ->
        error

      show ->
        dbg(show)
        {:error, "Invalid token: Parse Failure"}
    end
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

  defp verify_not_expired(%__MODULE__{} = access_token) do
    expires = DateTime.new!(access_token.expires_at, Time.new!(0, 0, 0, 0), "Etc/UTC")

    DateTime.before?(DateTime.utc_now(), expires)
  end

  def delete(access_token) do
    Repo.delete(access_token, skip_org_id: true)
  end

  def get(id) do
    query = from at in AccessToken, where: at.id == ^id

    case Sower.Repo.one(query, skip_org_id: true) do
      nil ->
        nil

      token ->
        token
        |> put_preview()
    end
  end

  def get!(id) do
    query = from at in AccessToken, where: at.id == ^id

    Sower.Repo.one!(query, skip_org_id: true)
    |> put_preview()
  end

  def list() do
    AccessToken |> Sower.Repo.all(skip_org_id: true)
  end

  def permission_roles() do
    Ecto.Enum.dump_values(Sower.Accounts.AccessToken.Permission, :role)
  end
end
