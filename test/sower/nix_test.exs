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

  describe "store_paths" do
    alias Sower.Nix.StorePath

    import Sower.NixFixtures

    @invalid_attrs %{path: nil}

    test "list_store_paths/0 returns all store_paths" do
      store_path = store_path_fixture()
      assert Nix.list_store_paths() == [store_path]
    end

    test "get_store_path!/1 returns the store_path with given id" do
      store_path = store_path_fixture()
      assert Nix.get_store_path!(store_path.id) == store_path
    end

    test "create_store_path/1 with valid data creates a store_path" do
      valid_attrs = %{path: "some path"}

      assert {:ok, %StorePath{} = store_path} = Nix.create_store_path(valid_attrs)
      assert store_path.path == "some path"
    end

    test "create_store_path/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Nix.create_store_path(@invalid_attrs)
    end

    test "update_store_path/2 with valid data updates the store_path" do
      store_path = store_path_fixture()
      update_attrs = %{path: "some updated path"}

      assert {:ok, %StorePath{} = store_path} = Nix.update_store_path(store_path, update_attrs)
      assert store_path.path == "some updated path"
    end

    test "update_store_path/2 with invalid data returns error changeset" do
      store_path = store_path_fixture()
      assert {:error, %Ecto.Changeset{}} = Nix.update_store_path(store_path, @invalid_attrs)
      assert store_path == Nix.get_store_path!(store_path.id)
    end

    test "delete_store_path/1 deletes the store_path" do
      store_path = store_path_fixture()
      assert {:ok, %StorePath{}} = Nix.delete_store_path(store_path)
      assert_raise Ecto.NoResultsError, fn -> Nix.get_store_path!(store_path.id) end
    end

    test "change_store_path/1 returns a store_path changeset" do
      store_path = store_path_fixture()
      assert %Ecto.Changeset{} = Nix.change_store_path(store_path)
    end
  end
end
