defmodule Sower.Accounts.AccessToken do
  use Sower.Schema

  alias Ecto.Changeset
  alias Sower.Accounts.AccessToken
  alias Sower.Repo

  import Ecto.Changeset
  import Ecto.Query

  require Logger
  @derive {Phoenix.Param, key: :sid}

  schema "access_tokens" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :expires_at, :date
    field :description, :string
    field :regenerate, :boolean, virtual: true
    field :token, :string, virtual: true
    field :token_hash, :string
    field :org_id, Ecto.UUID

    belongs_to :user, Sower.Accounts.User

    embeds_many :permissions, Permission, on_replace: :delete do
      field :role, Ecto.Enum,
        values: [:"seed:read", :"seed:write", :"nix-cache:read", :"agent:register"]
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

  def create(%AccessToken{} = access_token, %{"expires_at" => _} = attrs) do
    access_token
    |> changeset(attrs)
    |> put_change(:regenerate, true)
    |> generate_token()
    |> Repo.insert()
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
        sid =
          case get_field(changeset, :sid) do
            nil ->
              SowerClient.Sid.generate()

            sid ->
              sid
          end

        rand = :crypto.strong_rand_bytes(48) |> Base.encode64()
        hash = Argon2.hash_password(rand)

        token = "sower_" <> sid <> "_" <> rand

        changeset
        |> put_change(:sid, sid)
        |> put_change(:token, token)
        |> put_change(:token_hash, hash)
    end
  end

  def split_token(token) do
    case String.split(token, "_") do
      ["sower", id, rand] ->
        {:ok, id, rand}

      _ ->
        {:error, "Invalid token: failed to split"}
    end
  end

  def update(%AccessToken{} = access_token, attrs) do
    access_token
    |> changeset(attrs)
    |> generate_token()
    |> Repo.update()
  end

  def authenticate(token) do
    with {:ok, sid, rand} <- split_token(token),
         access_token <- get_sid(sid),
         false <- is_nil(access_token),
         true <- verify_not_expired(access_token),
         :ok <- verify_token(rand, access_token) do
      {:ok, access_token |> Sower.Repo.preload(:user)}
    else
      {:error, err} ->
        {:error, IO.inspect(err)}

      _ ->
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

  defp verify_token(hash_to_check, access_token) do
    if Argon2.verify_password(hash_to_check, access_token.token_hash) do
      :ok
    else
      {:error, "Invalid token: Hash Verify Failure"}
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

    Sower.Repo.one(query, skip_org_id: true)
  end

  def get!(id) do
    query = from at in AccessToken, where: at.id == ^id

    Sower.Repo.one!(query, skip_org_id: true)
  end

  def get_sid(sid) do
    query = from at in AccessToken, where: at.sid == ^sid

    Sower.Repo.one(query, skip_org_id: true)
  end

  def get_sid!(sid) do
    query = from at in AccessToken, where: at.sid == ^sid

    Sower.Repo.one!(query, skip_org_id: true)
  end

  def list() do
    AccessToken |> Sower.Repo.all(skip_org_id: true)
  end

  def permission_roles() do
    Ecto.Enum.dump_values(Sower.Accounts.AccessToken.Permission, :role)
  end
end
