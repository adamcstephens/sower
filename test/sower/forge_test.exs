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

    @invalid_attrs %{name: nil, type: nil, url: nil, client_id: nil, client_secret: nil}

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
end
