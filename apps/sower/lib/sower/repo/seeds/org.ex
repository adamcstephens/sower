defmodule Sower.Repo.Seeds.Org do
  require Logger

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
      case Sower.Repo.all_by(Sower.Accounts.User, [email: org_seed.email], skip_org_id: true) do
        [] ->
          {:ok, org} = Sower.Accounts.Organization.create(%{name: org_seed.name})
          Sower.Repo.put_org_id(org.org_id)

          Sower.Accounts.User.new(%{
            email: org_seed.email,
            name: ~s"#{org_seed.name} (seeded)",
            org_id: org.org_id,
            oidc_id: Ecto.UUID.generate()
          })

        [user] ->
          {:ok, user}

        other ->
          Logger.error(msg: "Too many matching users", other: other)
          Kernel.exit(1)
      end

    user
  end

  def access_token(%Sower.Accounts.User{} = user, name \\ "token", opts \\ %{}) do
    Sower.Repo.put_org_id(user.org_id)

    {:ok, access_token} =
      Sower.Accounts.AccessToken.create(
        Enum.into(opts, %{
          "permissions" => [
            %{
              "role" => "seed:write"
            },
            %{
              "role" => "agent:register"
            }
          ],
          "user_id" => user.id,
          "org_id" => user.org_id,
          "description" => name
        })
      )

    access_token
  end

  def fake_seeds(%Sower.Accounts.User{} = user) do
    Sower.Repo.put_org_id(user.org_id)

    Enum.to_list(1..5)
    |> Enum.map(fn t ->
      name = ~s"test#{t}"

      case Sower.Seed.get(name, "nixos") do
        nil ->
          Sower.Seed.create(%{
            name: name,
            seed_type: "nixos",
            org_id: user.org_id,
            artifact:
              ~s"/nix/store/#{Cuid2Ex.create(length: 32) |> String.downcase()}-nixos-system-#{name}-24.11.20240703.9f4128e"
          })

        seed ->
          {:ok, seed}
      end
    end)
  end
end
