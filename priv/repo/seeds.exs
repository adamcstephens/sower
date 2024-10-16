# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Sower.Repo.insert!(%Sower.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

defmodule Sower.Priv.Seeds do
  def gen_org(name) do
    {:ok, org} = Sower.Accounts.Organization.create(%{name: name})
    Sower.Repo.put_org_id(org.org_id)

    {:ok, user} =
      Sower.Accounts.User.new(%{
        email: ~s"#{name}@sower.dev",
        name: ~s"#{name} User",
        org_id: org.org_id,
        oidc_id: Ecto.UUID.generate()
      })

    {:ok, access_token, _token} =
      Sower.Accounts.AccessToken.create(%{
        "permissions" => [
          %{
            "action" => "read",
            "resource" => "Elixir.Sower.Seed"
          }
        ],
        "user_id" => user.id,
        "org_id" => user.org_id,
        "description" => ~s"token #{name}"
      })

    Enum.to_list(1..20)
    |> Enum.map(fn t ->
      name = ~s"test#{t}"

      {:ok, seed} =
        Sower.Seed.create(%{
          name: name,
          seed_type: "nixos",
          org_id: org.org_id
        })

      Sower.Seed.submit(
        seed,
        ~s"/nix/store/fqf9pp2pbcv64j0bz3mwv5grj60jkvzv-nixos-system-#{name}-24.11.20240703.9f4128e"
      )
    end)
  end
end

Sower.Priv.Seeds.gen_org("seed")
Sower.Priv.Seeds.gen_org("trial")
