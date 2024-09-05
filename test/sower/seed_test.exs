defmodule Sower.SeedTest do
  use Sower.DataCase

  import Sower.SeedFixtures

  alias Sower.Seed

  describe "latest/1" do
    test "does not return the seed if name does not exist" do
      refute Seed.latest("unknown", "nixos")
    end

    test "returns the seed if name exists" do
      %{id: id} = seed = seed_fixture()

      assert %Seed{id: ^id} = Seed.latest(seed.name, "nixos")
    end
  end

  describe "submit/1" do
    test "creates the seed if it does not exist" do
      name = unique_seed_name()

      refute Seed.latest(name, "nixos")

      %{id: id} = seed = seed_fixture(%{name: name})
      assert %Seed{id: ^id} = Seed.latest(seed.name, "nixos")
    end

    test "adds a store path if seed already exists" do
      seed = seed_fixture()

      {:ok, seed} =
        Seed.submit(%{name: seed.name, seed_type: seed.seed_type, store_path: random_store_path()})

      seed = seed |> Sower.Repo.preload(:store_paths)

      assert Enum.count(seed.store_paths) == 2

      {:ok, seed} =
        Seed.submit(%{name: seed.name, seed_type: seed.seed_type, store_path: random_store_path()})

      seed = seed |> Sower.Repo.preload(:store_paths)

      assert Enum.count(seed.store_paths) == 3
    end

    test "no new store paths if seed and path already exist" do
      store_path = random_store_path()
      seed = seed_fixture(%{store_path: store_path})

      {:ok, seed} =
        Seed.submit(%{name: seed.name, seed_type: seed.seed_type, store_path: store_path})

      seed = seed |> Sower.Repo.preload(:store_paths)

      assert Enum.count(seed.store_paths) == 1
      assert Repo.all(Sower.StorePath) |> Enum.count() == 1
    end
  end
end
