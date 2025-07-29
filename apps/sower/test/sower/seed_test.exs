defmodule Sower.SeedTest do
  use Sower.DataCase

  import Sower.AccountsFixtures
  import Sower.SeedFixtures

  alias Sower.Seed

  setup _ do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  describe "latest/1" do
    test "does not return the seed if name does not exist" do
      refute Seed.latest("unknown", "nixos")
    end

    test "returns the seed if name exists" do
      %{id: id} = seed = seed_fixture()

      assert %Seed{id: ^id} = Seed.latest(seed.name, "nixos")
    end
  end

  describe "create/1" do
    test "creates the seed if it does not exist" do
      name = unique_seed_name()

      refute Seed.latest(name, "nixos")

      %{id: id} = seed = seed_fixture(%{name: name})
      assert %Seed{id: ^id} = Seed.latest(seed.name, "nixos")
    end

    test "upserts" do
      seed = seed_fixture()

      {:ok, _} = Seed.create(Map.from_struct(seed))

      assert Repo.all(Sower.Seed) |> Enum.count() == 1
    end
  end
end
