defmodule Sower.Accounts.AccessToken do
  use Sower.Schema
  use Joken.Config

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
    field :token_subset, :string
    field :org_id, Ecto.UUID

    belongs_to :user, Sower.Accounts.User

    embeds_many :permissions, Permission, on_replace: :delete do
      field :action, Ecto.Enum, values: [:read, :update]
      field :resource, Ecto.Enum, values: [Sower.Seed]
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
    |> cast(attrs, [:action, :resource])
    |> validate_required([:action, :resource])
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

  def create() do
    create(%{})
  end

  defp regenerate_token(%Changeset{} = changeset) do
    case get_field(changeset, :regenerate) do
      false ->
        changeset

      _ ->
        token =
          sign_token(get_field(changeset, :id))

        changeset
        |> put_change(:token, token)
        |> put_change(:token_subset, String.slice(token, -12..-1))
    end
  end

  defp generate_token({:ok, %AccessToken{} = access_token}) do
    token = sign_token(access_token.id)

    {:ok,
     access_token
     |> Map.put(:token, token)
     |> Map.put(:token_subset, String.slice(token, -12..-1))}
  end

  def verify_token(token) do
    signer = Joken.Signer.create("HS256", "secret")

    AccessToken.verify_and_validate(token, signer)
  end

  def split_token(decrypted_token) do
    case String.split(decrypted_token, ":") do
      [_, _] = ids -> {:ok, ids}
      _ -> {:error, "invalid token"}
    end
  end

  defp sign_token(id) do
    signer = Joken.Signer.create("HS256", "secret")

    {:ok, token, _claims} =
      AccessToken.generate_and_sign(%{id: id}, signer) |> dbg()

    "sower_" <> token
  end

  def update(%AccessToken{} = access_token, attrs) do
    access_token
    |> changeset(attrs)
    |> regenerate_token()
    |> Repo.update(skip_org_id: true)
  end

  def authenticate(token) do
    with "sower_" <> token <- token,
         {:ok, claims} <- verify_token(token) |> dbg(),
         %{"id" => id} <- claims |> dbg(),
         access_token <- get(id) |> dbg() do
      case access_token do
        nil ->
          {:error, "Invalid token: Not found"}

        _ ->
          if access_token.token_subset == String.slice(token, -12..-1) do
            {:ok, access_token |> Sower.Repo.preload(:user)}
          else
            {:error, "Invalid token: Token Mismatch"}
          end
      end
    else
      {:error, _} = error ->
        error

      _ ->
        {:error, "Invalid token: Parse Failure"}
    end
  end

  defp expires_at_to_max_age(expires_at, %NaiveDateTime{} = from) do
    {:ok, from} = DateTime.from_naive(from, "Etc/UTC")
    expires_at_to_max_age(expires_at, from)
  end

  defp expires_at_to_max_age(expires_at, from) do
    {:ok, expire} =
      expires_at
      |> DateTime.new(Time.new!(0, 0, 0))

    expire
    |> DateTime.diff(from)
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

  def get(id) do
    query = from at in AccessToken, where: at.id == ^id
    Sower.Repo.one(query, skip_org_id: true)
  end

  def get!(id) do
    query = from at in AccessToken, where: at.id == ^id
    Sower.Repo.one!(query, skip_org_id: true)
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
