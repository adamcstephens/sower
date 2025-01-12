defmodule Sower.NixTest do
  use Sower.DataCase

  alias Sower.Nix
  import Sower.AccountsFixtures

  setup _ do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  describe "nix_caches" do
    alias Sower.Nix.Cache

    import Sower.NixFixtures

    @invalid_attrs %{public_key: nil, url: nil}

    test "list_nix_caches/0 returns all nix_caches" do
      cache = cache_fixture()
      assert Nix.list_nix_caches() == [cache]
    end

    test "get_cache!/1 returns the cache with given id" do
      cache = cache_fixture()
      assert Nix.get_cache!(cache.id) == cache
    end

    test "create_cache/1 with valid data creates a cache" do
      valid_attrs = %{public_key: "some public_key", url: "some url"}

      assert {:ok, %Cache{} = cache} = Nix.create_cache(valid_attrs)
      assert cache.public_key == "some public_key"
      assert cache.url == "some url"
    end

    test "create_cache/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Nix.create_cache(@invalid_attrs)
    end

    test "update_cache/2 with valid data updates the cache" do
      cache = cache_fixture()
      update_attrs = %{public_key: "some updated public_key", url: "some updated url"}

      assert {:ok, %Cache{} = cache} = Nix.update_cache(cache, update_attrs)
      assert cache.public_key == "some updated public_key"
      assert cache.url == "some updated url"
    end

    test "update_cache/2 with invalid data returns error changeset" do
      cache = cache_fixture()
      assert {:error, %Ecto.Changeset{}} = Nix.update_cache(cache, @invalid_attrs)
      assert cache == Nix.get_cache!(cache.id)
    end

    test "delete_cache/1 deletes the cache" do
      cache = cache_fixture()
      assert {:ok, %Cache{}} = Nix.delete_cache(cache)
      assert_raise Ecto.NoResultsError, fn -> Nix.get_cache!(cache.id) end
    end

    test "change_cache/1 returns a cache changeset" do
      cache = cache_fixture()
      assert %Ecto.Changeset{} = Nix.change_cache(cache)
    end
  end
end
