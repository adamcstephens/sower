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

  describe "latest/3 with tag filtering" do
    test "returns nil when no seed matches the tags" do
      seed_fixture(%{tags: [%{key: "env", value: "prod"}]})

      refute Seed.latest("unknown", "nixos", [%{key: "env", value: "prod"}])
    end

    test "returns nil when seed exists but tags don't match" do
      name = unique_seed_name()
      seed_fixture(%{name: name, tags: [%{key: "env", value: "prod"}]})

      refute Seed.latest(name, "nixos", [%{key: "env", value: "staging"}])
    end

    test "returns the seed when all tags match" do
      name = unique_seed_name()
      %{id: id} = seed_fixture(%{name: name, tags: [%{key: "env", value: "prod"}]})

      assert %Seed{id: ^id} = Seed.latest(name, "nixos", [%{key: "env", value: "prod"}])
    end

    test "returns the seed when multiple tags all match" do
      name = unique_seed_name()

      %{id: id} =
        seed_fixture(%{
          name: name,
          tags: [
            %{key: "env", value: "prod"},
            %{key: "git_branch", value: "main"}
          ]
        })

      assert %Seed{id: ^id} =
               Seed.latest(name, "nixos", [
                 %{key: "env", value: "prod"},
                 %{key: "git_branch", value: "main"}
               ])
    end

    test "returns nil when only some tags match" do
      name = unique_seed_name()

      seed_fixture(%{
        name: name,
        tags: [
          %{key: "env", value: "prod"}
        ]
      })

      refute Seed.latest(name, "nixos", [
               %{key: "env", value: "prod"},
               %{key: "git_branch", value: "main"}
             ])
    end

    test "returns the seed when querying with subset of tags" do
      name = unique_seed_name()

      %{id: id} =
        seed_fixture(%{
          name: name,
          tags: [
            %{key: "env", value: "prod"},
            %{key: "git_branch", value: "main"}
          ]
        })

      # Seed has more tags than we query for - should still match
      assert %Seed{id: ^id} = Seed.latest(name, "nixos", [%{key: "env", value: "prod"}])
    end

    test "returns latest seed when multiple seeds match tags" do
      name = unique_seed_name()
      tags = [%{key: "env", value: "prod"}]

      # Create first seed
      seed_fixture(%{name: name, tags: tags})

      # Create second seed with same name and tags but different artifact
      %{id: latest_id} = seed_fixture(%{name: name, tags: tags})

      assert %Seed{id: ^latest_id} = Seed.latest(name, "nixos", tags)
    end

    test "delegates to latest/2 when tags list is empty" do
      name = unique_seed_name()
      %{id: id} = seed_fixture(%{name: name})

      assert %Seed{id: ^id} = Seed.latest(name, "nixos", [])
    end
  end
end
