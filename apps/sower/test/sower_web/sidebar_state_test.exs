defmodule SowerWeb.SidebarStateTest do
  use SowerWeb.ConnCase, async: true

  alias SowerWeb.SidebarState

  describe "call/2" do
    setup %{conn: conn} do
      conn =
        conn
        |> Map.replace!(:secret_key_base, SowerWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> fetch_cookies()

      %{conn: conn}
    end

    test "defaults to :expanded when no cookie is present", %{conn: conn} do
      conn = SidebarState.call(conn, [])

      assert conn.assigns.sidebar_state == :expanded
      assert get_session(conn, :sidebar_state) == :expanded
    end

    test "reads :rail from the sidebar cookie", %{conn: conn} do
      conn = %{conn | cookies: Map.put(conn.cookies, "sidebar", "rail")}
      conn = SidebarState.call(conn, [])

      assert conn.assigns.sidebar_state == :rail
      assert get_session(conn, :sidebar_state) == :rail
    end

    test "falls back to :expanded on unrecognized cookie value", %{conn: conn} do
      conn = %{conn | cookies: Map.put(conn.cookies, "sidebar", "garbage")}
      conn = SidebarState.call(conn, [])

      assert conn.assigns.sidebar_state == :expanded
    end
  end

  describe "on_mount/4" do
    test "reads sidebar_state from session and assigns to socket" do
      {:cont, socket} =
        SidebarState.on_mount(:default, %{}, %{"sidebar_state" => :rail}, mount_socket())

      assert socket.assigns.sidebar_state == :rail
    end

    test "defaults to :expanded when session is empty" do
      {:cont, socket} = SidebarState.on_mount(:default, %{}, %{}, mount_socket())

      assert socket.assigns.sidebar_state == :expanded
    end
  end

  defp mount_socket do
    %Phoenix.LiveView.Socket{
      endpoint: SowerWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{
        connect_params: %{},
        lifecycle: %Phoenix.LiveView.Lifecycle{}
      }
    }
  end
end
