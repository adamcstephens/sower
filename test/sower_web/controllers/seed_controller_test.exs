defmodule SowerWeb.SeedControllerTest do
  use SowerWeb.ConnCase

  import Sower.TestFixtures

  alias Sower.Test.Seed

  @create_attrs %{

  }
  @update_attrs %{

  }
  @invalid_attrs %{}

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all seeds", %{conn: conn} do
      conn = get(conn, ~p"/api/seeds")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create seed" do
    test "renders seed when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/seeds", seed: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/seeds/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/seeds", seed: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update seed" do
    setup [:create_seed]

    test "renders seed when data is valid", %{conn: conn, seed: %Seed{id: id} = seed} do
      conn = put(conn, ~p"/api/seeds/#{seed}", seed: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/seeds/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, seed: seed} do
      conn = put(conn, ~p"/api/seeds/#{seed}", seed: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete seed" do
    setup [:create_seed]

    test "deletes chosen seed", %{conn: conn, seed: seed} do
      conn = delete(conn, ~p"/api/seeds/#{seed}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/api/seeds/#{seed}")
      end
    end
  end

  defp create_seed(_) do
    seed = seed_fixture()
    %{seed: seed}
  end
end
