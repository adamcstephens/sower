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

Enum.to_list(1..20)
|> Enum.map(fn t ->
  name = ~s"test#{t}"

  Sower.Seed.submit(%{
    name: name,
    seed_type: "nixos",
    store_path:
      ~s"/nix/store/fqf9pp2pbcv64j0bz3mwv5grj60jkvzv-nixos-system-#{name}-24.11.20240703.9f4128e"
  })
end)
