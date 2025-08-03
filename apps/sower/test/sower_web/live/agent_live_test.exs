defmodule SowerWeb.AgentLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  defp create_agent(%{user: %{org_id: org_id}}) do
    agent = agent_fixture(%{org_id: org_id})
    %{agent: agent}
  end

  describe "Index" do
    setup [:register_and_log_in_user, :create_agent]

    test "lists all agents", %{conn: conn, agent: agent} do
      {:ok, _index_live, html} = live(conn, ~p"/agents")

      assert html =~ "Listing Agents"
      assert html =~ agent.sid
    end

    test "deletes agent in listing", %{conn: conn, agent: agent} do
      {:ok, index_live, _html} = live(conn, ~p"/agents")

      assert index_live |> element("#agents-#{agent.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#agents-#{agent.id}")
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user, :create_agent]

    test "displays agent", %{conn: conn, agent: agent} do
      {:ok, _show_live, html} = live(conn, ~p"/agents/#{agent}")

      assert html =~ "Show Agent"
      assert html =~ agent.sid
    end
  end
end
