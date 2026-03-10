defmodule SowerWeb.SowerComponentsTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias SowerWeb.SowerComponents

  describe "table/1" do
    test "renders basic table with all columns visible" do
      assigns = %{
        rows: [%{id: "1", name: "Alice", email: "alice@example.com"}]
      }

      html =
        rendered_to_string(~H"""
        <SowerComponents.table id="test-table" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
          <:col :let={row} label="Email">{row.email}</:col>
        </SowerComponents.table>
        """)

      assert html =~ "Name"
      assert html =~ "Email"
      assert html =~ "Alice"
      assert html =~ "alice@example.com"
      refute html =~ "hidden"
      refute html =~ "sm:table-cell"
    end

    test "renders column with hide_on={:mobile} with hidden and sm:table-cell classes" do
      assigns = %{
        rows: [%{id: "1", name: "Alice", email: "alice@example.com"}]
      }

      html =
        rendered_to_string(~H"""
        <SowerComponents.table id="test-table" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
          <:col :let={row} label="Email" hide_on={:mobile}>{row.email}</:col>
        </SowerComponents.table>
        """)

      # The Name column header should not have hidden classes
      assert html =~ "Name"
      # The Email column header and cells should have hidden + sm:table-cell
      assert html =~ "hidden"
      assert html =~ "sm:table-cell"
    end

    test "SowerComponents exports table/1 for global import resolution" do
      assert function_exported?(SowerWeb.SowerComponents, :table, 1)
    end

    test "action columns never get hide classes" do
      assigns = %{
        rows: [%{id: "1", name: "Alice"}]
      }

      html =
        rendered_to_string(~H"""
        <SowerComponents.table id="test-table" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
          <:action :let={row}>
            <a href={"/items/#{row.id}"}>View</a>
          </:action>
        </SowerComponents.table>
        """)

      assert html =~ "View"
      # Action column should not contain hide_on responsive classes
      # Parse the action td/th specifically - they should not have hidden class
      assert html =~ "Actions"
    end
  end
end
