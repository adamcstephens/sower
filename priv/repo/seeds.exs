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

{:ok, org} = Sower.Accounts.Organization.create(%{name: "dev"})
Sower.Repo.put_org_id(org.org_id)

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
