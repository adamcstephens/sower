defmodule SowerWeb.LayoutsTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias SowerWeb.Layouts

  defp render_app(assigns) do
    assigns =
      Map.merge(
        %{
          flash: %{},
          current_user: nil,
          nav_section: nil,
          sidebar_state: :expanded,
          crumbs: []
        },
        assigns
      )

    rendered_to_string(~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      nav_section={@nav_section}
      sidebar_state={@sidebar_state}
      crumbs={@crumbs}
    >
      <p>body</p>
    </Layouts.app>
    """)
  end

  describe "sidebar state" do
    test "expanded state renders the full width and the wordmark" do
      html = render_app(%{sidebar_state: :expanded})

      assert html =~ ~s(data-sidebar="expanded")
      assert html =~ "w-[232px]"
      assert html =~ ">\n    Sower\n  </span>"
      refute html =~ "w-14"
    end

    test "rail state renders the collapsed width and hides the wordmark" do
      html = render_app(%{sidebar_state: :rail})

      assert html =~ ~s(data-sidebar="rail")
      assert html =~ "w-14"
      refute html =~ "w-[232px]"
      refute html =~ ">\n    Sower\n  </span>"
    end

    test "renders a toggle button that emits the toggle_sidebar event" do
      html = render_app(%{sidebar_state: :expanded})

      assert html =~ ~s(phx-click="toggle_sidebar")
      assert html =~ ~s(aria-label="Collapse sidebar")

      html = render_app(%{sidebar_state: :rail})
      assert html =~ ~s(aria-label="Expand sidebar")
    end
  end

  describe "active nav item" do
    for {section, label} <- [
          {:gardens, "Gardens"},
          {:seeds, "Seeds"},
          {:deployments, "Deployments"},
          {:forges, "Forges"},
          {:caches, "Nix caches"}
        ] do
      test "marks the #{section} item as the active page" do
        html = render_app(%{nav_section: unquote(section)})

        # active item has aria-current=page and the amber bar
        assert html =~ ~s(aria-current="page")
        assert html =~ "bg-amber-500"

        active_pattern =
          ~r/aria-current="page"[^>]*>\s*<span[^>]*bg-amber-500[^>]*>.*?#{unquote(label)}/s

        assert Regex.match?(active_pattern, html),
               "Expected #{unquote(label)} to be the active item"
      end
    end
  end

  describe "topbar" do
    test "renders the user dropdown when current_user is set" do
      user = %{name: "Ada Lovelace"}
      html = render_app(%{current_user: user})

      assert html =~ "user-menu-button"
      assert html =~ "user-dropdown"
      assert html =~ "Hello, Ada Lovelace!"
      assert html =~ ~s(href="/settings/access-tokens")
      assert html =~ ~s(href="/settings")
      assert html =~ "Sign out"
    end

    test "renders sign in when there is no current_user" do
      html = render_app(%{current_user: nil})

      assert html =~ "Sign In"
      refute html =~ "user-dropdown"
    end

    test "renders default crumbs from the nav_section" do
      html = render_app(%{nav_section: :gardens})

      assert html =~ ~s(aria-label="Breadcrumb")
      assert html =~ ~s(aria-current="page")
      assert html =~ "Gardens"
    end

    test "renders explicit crumbs over the nav_section default" do
      html =
        render_app(%{
          nav_section: :gardens,
          crumbs: [{"Gardens", "/gardens"}, {"bank1", nil}]
        })

      assert html =~ ~s(href="/gardens")
      assert html =~ "bank1"
    end
  end
end
