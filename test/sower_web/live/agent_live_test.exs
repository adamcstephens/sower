defmodule SowerWeb.AgentLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  @create_attrs %{sid: "some sid", remote_sid: "some remote_sid"}
  @update_attrs %{sid: "some updated sid", remote_sid: "some updated remote_sid"}
  @invalid_attrs %{sid: nil, remote_sid: nil}

  defp create_agent(_) do
    agent = agent_fixture()
    %{agent: agent}
  end

  describe "Index" do
    setup [:create_agent]

    test "lists all agents", %{conn: conn, agent: agent} do
      {:ok, _index_live, html} = live(conn, ~p"/agents")

      assert html =~ "Listing Agents"
      assert html =~ agent.sid
    end

    test "saves new agent", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/agents")

      assert index_live |> element("a", "New Agent") |> render_click() =~
               "New Agent"

      assert_patch(index_live, ~p"/agents/new")

      assert index_live
             |> form("#agent-form", agent: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#agent-form", agent: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/agents")

      html = render(index_live)
      assert html =~ "Agent created successfully"
      assert html =~ "some sid"
    end

    test "updates agent in listing", %{conn: conn, agent: agent} do
      {:ok, index_live, _html} = live(conn, ~p"/agents")

      assert index_live |> element("#agents-#{agent.id} a", "Edit") |> render_click() =~
               "Edit Agent"

      assert_patch(index_live, ~p"/agents/#{agent}/edit")

      assert index_live
             |> form("#agent-form", agent: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#agent-form", agent: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/agents")

      html = render(index_live)
      assert html =~ "Agent updated successfully"
      assert html =~ "some updated sid"
    end

    test "deletes agent in listing", %{conn: conn, agent: agent} do
      {:ok, index_live, _html} = live(conn, ~p"/agents")

      assert index_live |> element("#agents-#{agent.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#agents-#{agent.id}")
    end
  end

  describe "Show" do
    setup [:create_agent]

    test "displays agent", %{conn: conn, agent: agent} do
      {:ok, _show_live, html} = live(conn, ~p"/agents/#{agent}")

      assert html =~ "Show Agent"
      assert html =~ agent.sid
    end

    test "updates agent within modal", %{conn: conn, agent: agent} do
      {:ok, show_live, _html} = live(conn, ~p"/agents/#{agent}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Agent"

      assert_patch(show_live, ~p"/agents/#{agent}/show/edit")

      assert show_live
             |> form("#agent-form", agent: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#agent-form", agent: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/agents/#{agent}")

      html = render(show_live)
      assert html =~ "Agent updated successfully"
      assert html =~ "some updated sid"
    end
  end
end
