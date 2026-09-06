defmodule SowerWeb.GardenLive.IndexTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  setup [:register_and_log_in_user]

  describe "live view" do
    test "Deploy column header is a sort link", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)
      garden_fixture()

      {:ok, live, _html} = live(conn, ~p"/gardens")

      assert has_element?(live, "th a", "Deploy")
    end

    test "filters Gardens by name", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)
      garden_fixture(%{name: "alpha-garden"})
      garden_fixture(%{name: "beta-garden"})

      {:ok, live, _html} = live(conn, ~p"/gardens")

      html =
        live
        |> form("#garden-filter", %{name: "alpha"})
        |> render_change()

      assert html =~ "alpha-garden"
      refute html =~ "beta-garden"
    end

    test "sorting by Deploy orders by latest deployment result", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)

      g_failure = garden_fixture(%{name: "g-failure"})
      g_success = garden_fixture(%{name: "g-success"})

      {:ok, _} =
        Sower.Orchestration.create_deployment(%{
          garden_id: g_failure.id,
          result: :failure,
          seeds: [],
          subscriptions: []
        })

      {:ok, _} =
        Sower.Orchestration.create_deployment(%{
          garden_id: g_success.id,
          result: :success,
          seeds: [],
          subscriptions: []
        })

      {:ok, _live, html} =
        live(conn, ~p"/gardens?order_by[]=deploy_result&order_directions[]=asc")

      assert html =~ ~r/g-failure.*g-success/s
    end
  end
end
