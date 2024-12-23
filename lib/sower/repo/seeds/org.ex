defmodule Sower.Repo.Seeds.Org do
  @enforce_keys [:name]
  defstruct [:name, :email]

  def new_org_and_user(%__MODULE__{} = org_seed) do
    org_seed =
      if is_nil(org_seed.email) do
        org_seed |> Map.put(:email, ~s"dev-#{org_seed.name}@sower.dev")
      else
        org_seed
      end

    {:ok, user} =
      case Sower.Accounts.User.get_by_email(org_seed.email) do
        nil ->
          {:ok, org} = Sower.Accounts.Organization.create(%{name: org_seed.name})
          Sower.Repo.put_org_id(org.org_id)

          Sower.Accounts.User.new(%{
            email: org_seed.email,
            name: ~s"#{org_seed.name} (seeded)",
            org_id: org.org_id,
            oidc_id: Ecto.UUID.generate()
          })

        user ->
          {:ok, user}
      end

    user
  end

  def access_token(%Sower.Accounts.User{} = user, name \\ "token") do
    Sower.Repo.put_org_id(user.org_id)

    {:ok, access_token} =
      Sower.Accounts.AccessToken.create(%{
        "permissions" => [
          %{
            "role" => "seed:write"
          }
        ],
        "user_id" => user.id,
        "org_id" => user.org_id,
        "description" => name
      })

    access_token
  end

  def fake_seeds(%Sower.Accounts.User{} = user) do
    Sower.Repo.put_org_id(user.org_id)

    Enum.to_list(1..20)
    |> Enum.map(fn t ->
      name = ~s"test#{t}"

      {:ok, seed} =
        case Sower.Seed.get(name, "nixos") do
          nil ->
            Sower.Seed.create(%{
              name: name,
              seed_type: "nixos",
              org_id: user.org_id
            })

          seed ->
            {:ok, seed}
        end

      Sower.Seed.submit(
        seed,
        ~s"/nix/store/fqf9pp2pbcv64j0bz3mwv5grj60jkvzv-nixos-system-#{name}-24.11.20240703.9f4128e"
      )
    end)
  end
end
