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

alias Sower.Repo.Seeds.Org

Org.new(%Org{name: "seed"})
Org.new(%Org{name: "trial"})
