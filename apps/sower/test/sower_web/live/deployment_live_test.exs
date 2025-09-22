defmodule SowerWeb.DeploymentLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  @create_attrs %{seed_name: "some seed_name", seed_type: "some seed_type"}
  @update_attrs %{seed_name: "some updated seed_name", seed_type: "some updated seed_type"}
  @invalid_attrs %{seed_name: nil, seed_type: nil}
  defp create_deployment(_) do
    deployment = deployment_fixture()

    %{deployment: deployment}
  end

  describe "Index" do
    setup [:create_deployment]

    test "lists all deployments", %{conn: conn, deployment: deployment} do
      {:ok, _index_live, html} = live(conn, ~p"/deployments")

      assert html =~ "Listing Deployments"
      assert html =~ deployment.seed_name
    end

    test "saves new deployment", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/deployments")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Deployment")
               |> render_click()
               |> follow_redirect(conn, ~p"/deployments/new")

      assert render(form_live) =~ "New Deployment"

      assert form_live
             |> form("#deployment-form", deployment: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#deployment-form", deployment: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/deployments")

      html = render(index_live)
      assert html =~ "Deployment created successfully"
      assert html =~ "some seed_name"
    end

    test "updates deployment in listing", %{conn: conn, deployment: deployment} do
      {:ok, index_live, _html} = live(conn, ~p"/deployments")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#deployments-#{deployment.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/deployments/#{deployment}/edit")

      assert render(form_live) =~ "Edit Deployment"

      assert form_live
             |> form("#deployment-form", deployment: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#deployment-form", deployment: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/deployments")

      html = render(index_live)
      assert html =~ "Deployment updated successfully"
      assert html =~ "some updated seed_name"
    end

    test "deletes deployment in listing", %{conn: conn, deployment: deployment} do
      {:ok, index_live, _html} = live(conn, ~p"/deployments")

      assert index_live |> element("#deployments-#{deployment.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#deployments-#{deployment.id}")
    end
  end

  describe "Show" do
    setup [:create_deployment]

    test "displays deployment", %{conn: conn, deployment: deployment} do
      {:ok, _show_live, html} = live(conn, ~p"/deployments/#{deployment}")

      assert html =~ "Show Deployment"
      assert html =~ deployment.seed_name
    end

    test "updates deployment and returns to show", %{conn: conn, deployment: deployment} do
      {:ok, show_live, _html} = live(conn, ~p"/deployments/#{deployment}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/deployments/#{deployment}/edit?return_to=show")

      assert render(form_live) =~ "Edit Deployment"

      assert form_live
             |> form("#deployment-form", deployment: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#deployment-form", deployment: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/deployments/#{deployment}")

      html = render(show_live)
      assert html =~ "Deployment updated successfully"
      assert html =~ "some updated seed_name"
    end
  end
end
