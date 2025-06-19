defmodule Sower.ForgeTest do
  use Sower.DataCase

  alias Sower.Forge
  import Sower.AccountsFixtures

  setup _ do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  describe "forges" do
    alias Sower.Forge.Connection

    import Sower.ForgeFixtures

    @invalid_attrs %{
      name: nil,
      type: nil,
      url: nil,
      client_id: nil,
      client_secret: nil
    }

    test "list_forges/0 returns all forges" do
      connection = connection_fixture()
      assert Forge.list_forges() == [connection]
    end

    test "get_connection!/1 returns the connection with given id" do
      connection = connection_fixture()
      assert Forge.get_connection!(connection.id) == connection
    end

    test "create_connection/1 with valid data creates a connection" do
      valid_attrs = %{
        name: "some name",
        type: :forgejo,
        url: "some url",
        client_id: "some client_id",
        client_secret: "some client_secret"
      }

      assert {:ok, %Connection{} = connection} = Forge.create_connection(valid_attrs)
      assert connection.name == "some name"
      assert connection.type == :forgejo
      assert connection.url == "some url"
      assert connection.client_id == "some client_id"
      assert connection.client_secret == "some client_secret"
    end

    test "create_connection/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Forge.create_connection(@invalid_attrs)
    end

    test "update_connection/2 with valid data updates the connection" do
      connection = connection_fixture()

      update_attrs = %{
        name: "some updated name",
        type: :forgejo,
        url: "some updated url",
        client_id: "some updated client_id",
        client_secret: "some updated client_secret"
      }

      assert {:ok, %Connection{} = connection} = Forge.update_connection(connection, update_attrs)
      assert connection.name == "some updated name"
      assert connection.type == :forgejo
      assert connection.url == "some updated url"
      assert connection.client_id == "some updated client_id"
      assert connection.client_secret == "some updated client_secret"
    end

    test "update_connection/2 with invalid data returns error changeset" do
      connection = connection_fixture()
      assert {:error, %Ecto.Changeset{}} = Forge.update_connection(connection, @invalid_attrs)
      assert connection == Forge.get_connection!(connection.id)
    end

    test "delete_connection/1 deletes the connection" do
      connection = connection_fixture()
      assert {:ok, %Connection{}} = Forge.delete_connection(connection)
      assert_raise Ecto.NoResultsError, fn -> Forge.get_connection!(connection.id) end
    end

    test "change_connection/1 returns a connection changeset" do
      connection = connection_fixture()
      assert %Ecto.Changeset{} = Forge.change_connection(connection)
    end
  end

  describe "repositories" do
    alias Sower.Forge.Repository

    import Sower.ForgeFixtures

    @invalid_attrs %{owner: nil, url: nil, webhook_id: nil}

    test "list_repositories/0 returns all repositories" do
      repository = repository_fixture()
      assert Forge.list_repositories() == [repository]
    end

    test "get_repository!/1 returns the repository with given id" do
      repository = repository_fixture()
      assert Forge.get_repository!(repository.id) == repository
    end

    test "create_repository/1 with valid data creates a repository" do
      valid_attrs = %{
        owner: "some owner",
        repo: "some repo",
        url: "some url",
        webhook_id: "some webhook_id",
        forge_id: connection_fixture().id
      }

      assert {:ok, %Repository{} = repository} = Forge.create_repository(valid_attrs)
      assert repository.owner == "some owner"
      assert repository.url == "some url"
      assert repository.webhook_id == "some webhook_id"
    end

    test "create_repository/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Forge.create_repository(@invalid_attrs)
    end

    test "update_repository/2 with valid data updates the repository" do
      repository = repository_fixture()

      update_attrs = %{
        owner: "some updated owner",
        repo: "some updated repo",
        url: "some updated url",
        webhook_id: "some updated webhook_id"
      }

      assert {:ok, %Repository{} = repository} = Forge.update_repository(repository, update_attrs)
      assert repository.owner == "some updated owner"
      assert repository.repo == "some updated repo"
      assert repository.url == "some updated url"
      assert repository.webhook_id == "some updated webhook_id"
    end

    test "update_repository/2 with invalid data returns error changeset" do
      repository = repository_fixture()
      assert {:error, %Ecto.Changeset{}} = Forge.update_repository(repository, @invalid_attrs)
      assert repository == Forge.get_repository!(repository.id)
    end

    test "delete_repository/1 deletes the repository" do
      repository = repository_fixture()
      assert {:ok, %Repository{}} = Forge.delete_repository(repository)
      assert_raise Ecto.NoResultsError, fn -> Forge.get_repository!(repository.id) end
    end

    test "change_repository/1 returns a repository changeset" do
      repository = repository_fixture()
      assert %Ecto.Changeset{} = Forge.change_repository(repository)
    end
  end
end
