defmodule SowerClientTest do
  use ExUnit.Case
  doctest SowerClient

  test "pending deployments require both the seed identity and its web link" do
    alias SowerClient.Orchestration.PendingDeployment

    payload = %{
      "seed_sid" => "seed_123",
      "seed_url" => "https://sower.example/seeds/seed_123"
    }

    assert {:ok, pending} = PendingDeployment.cast(payload)
    assert Jason.decode!(Jason.encode!(pending)) == payload

    for field <- ["seed_sid", "seed_url"] do
      assert {:error, _} = PendingDeployment.cast(Map.delete(payload, field))
    end
  end

  describe "built seed manifests" do
    alias SowerClient.SeedManifest

    setup do
      {:ok,
       payload: %{
         "version" => 1,
         "name" => "myhost",
         "seed_type" => "nixos",
         "artifact" => "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos",
         "tags" => %{"environment" => "production", "user" => "alice"}
       }}
    end

    test "casts every supported seed type and preserves string-keyed tags", %{payload: payload} do
      for seed_type <- ["nixos", "home-manager", "nix-darwin", "service"],
          tags <- [payload["tags"], %{}, %{"empty" => "", "" => "value"}] do
        input = %{payload | "seed_type" => seed_type, "tags" => tags}

        assert {:ok, %SeedManifest{} = manifest} = SeedManifest.cast(input)
        assert manifest.version == 1
        assert manifest.name == input["name"]
        assert manifest.seed_type == seed_type
        assert manifest.artifact == input["artifact"]
        assert manifest.tags == tags
        assert Jason.decode!(Jason.encode!(manifest)) == input
      end
    end

    test "requires every manifest field", %{payload: payload} do
      for field <- ["version", "name", "seed_type", "artifact", "tags"] do
        assert {:error, _} = SeedManifest.cast(Map.delete(payload, field))
        assert {:error, _} = SeedManifest.cast(Map.put(payload, field, nil))
      end
    end

    test "rejects unsupported versions and malformed field types", %{payload: payload} do
      for version <- [0, 2, -1, "1", 1.0, true, %{}] do
        assert {:error, _} = SeedManifest.cast(%{payload | "version" => version})
      end

      for name <- ["", 7, :myhost, [], %{}] do
        assert {:error, _} = SeedManifest.cast(%{payload | "name" => name})
      end

      for seed_type <- ["", "unknown", :nixos, 7, []] do
        assert {:error, _} = SeedManifest.cast(%{payload | "seed_type" => seed_type})
      end

      for tags <- [
            [],
            "production",
            %{"environment" => 7},
            %{"user" => :alice},
            %{"user" => nil},
            %{"nested" => %{}},
            %{user: "alice"}
          ] do
        assert {:error, _} = SeedManifest.cast(%{payload | "tags" => tags})
      end
    end

    test "rejects malformed store paths", %{payload: payload} do
      for artifact <- [
            "",
            "/tmp/nixos",
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos",
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos",
            "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-nixos",
            "/nix/store/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-nixos",
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-",
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos/bin",
            7
          ] do
        assert {:error, _} = SeedManifest.cast(%{payload | "artifact" => artifact})
      end
    end

    test "rejects unknown properties and non-object payloads", %{payload: payload} do
      assert {:error, _} = SeedManifest.cast(Map.put(payload, "sid", "seed_123"))

      for input <- [nil, [], "manifest", 1] do
        assert {:error, _} = SeedManifest.cast(input)
      end
    end
  end
end
