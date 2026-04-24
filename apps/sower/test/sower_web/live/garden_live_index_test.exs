defmodule SowerWeb.GardenLive.IndexTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  alias SowerWeb.GardenLive.Index

  setup [:register_and_log_in_user]

  describe "parse_cols/1" do
    test "absent param falls back to defaults" do
      assert Index.parse_cols(%{}) == MapSet.new([:name, :online, :deploy])
    end

    test "empty string falls back to defaults" do
      assert Index.parse_cols(%{"cols" => ""}) == MapSet.new([:name, :online, :deploy])
    end

    test "all-unknown values fall back to defaults" do
      assert Index.parse_cols(%{"cols" => "nope,missing"}) ==
               MapSet.new([:name, :online, :deploy])
    end

    test "known values are kept" do
      assert Index.parse_cols(%{"cols" => "version,deploy"}) ==
               MapSet.new([:name, :version, :deploy])
    end

    test "unknown values are dropped, known kept" do
      assert Index.parse_cols(%{"cols" => "version,whatever"}) ==
               MapSet.new([:name, :version])
    end

    test "duplicates are deduped" do
      assert Index.parse_cols(%{"cols" => "version,version"}) ==
               MapSet.new([:name, :version])
    end

    test "lockable keys are always included" do
      assert :name in Index.parse_cols(%{"cols" => "version"})
    end
  end

  describe "cols_query_string/1" do
    test "returns empty string for default set" do
      assert Index.cols_query_string(MapSet.new([:name, :online, :deploy])) == ""
    end

    test "returns cols param preserving @columns order" do
      assert Index.cols_query_string(MapSet.new([:version, :name])) ==
               "?cols=name,version"
    end

    test "roundtrips through parse_cols" do
      set = MapSet.new([:name, :version])
      "?" <> query = Index.cols_query_string(set)
      params = URI.decode_query(query)
      assert Index.parse_cols(params) == set
    end
  end

  describe "live view" do
    test "default view hides version column data", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)
      garden_fixture(%{version: "hidden-default-version"})

      {:ok, _view, html} = live(conn, ~p"/gardens")

      assert html =~ "Name"
      assert html =~ "Online"
      assert html =~ "Deploy"
      refute html =~ "hidden-default-version"
    end

    test "renders Version column when cols includes version", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)
      garden_fixture(%{version: "1.2.3"})

      {:ok, _view, html} = live(conn, ~p"/gardens?cols=name,version")

      assert html =~ ~r/>\s*Version\s*</
      assert html =~ "1.2.3"
    end

    test "toggle_col adds a column and updates URL", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)
      garden_fixture(%{version: "9.9.9"})

      {:ok, view, _html} = live(conn, ~p"/gardens")

      view
      |> element("input[phx-value-col=\"version\"]")
      |> render_click()

      assert_patch(view)
      html = render(view)
      assert html =~ ~r/>\s*Version\s*</
      assert html =~ "9.9.9"
    end

    test "Deploy column header is a sort link", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)
      garden_fixture()

      {:ok, live, _html} = live(conn, ~p"/gardens")

      assert has_element?(live, "th a", "Deploy")
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

    test "sort preserved when column hidden then re-shown", %{conn: conn, user: user} do
      Sower.Repo.put_org_id(user.org_id)
      garden_fixture(%{name: "a", version: "2.0"})
      garden_fixture(%{name: "b", version: "1.0"})

      {:ok, view, html} =
        live(conn, ~p"/gardens?cols=name,version&order_by[]=version&order_directions[]=asc")

      assert html =~ "2.0"

      view
      |> element("input[phx-value-col=\"version\"]")
      |> render_click()

      hidden_path = assert_patch(view)
      assert hidden_path =~ "order_by"
      refute render(view) =~ "2.0"

      view
      |> element("input[phx-value-col=\"version\"]")
      |> render_click()

      shown_path = assert_patch(view)
      assert shown_path =~ "order_by"
      assert render(view) =~ "2.0"
    end
  end
end
