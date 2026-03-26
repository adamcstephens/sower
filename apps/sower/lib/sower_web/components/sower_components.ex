defmodule SowerWeb.SowerComponents do
  use Phoenix.Component
  use Gettext, backend: SowerWeb.Gettext
  import SowerWeb.CoreComponents, only: [button: 1]

  @doc """
  Renders a table with responsive column hiding and optional sortable headers.

  Columns can be hidden below a breakpoint by setting `hide_on={:sm}` (or `:md`, `:lg`, `:xl`)
  on the `:col` slot, which applies `hidden <bp>:table-cell` classes to both `<th>` and `<td>`.

  For sortable columns, set `field={:field_name}` on the `:col` slot and provide `meta` and `path`
  on the table. Columns without `field` render plain labels as before.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil
  attr :row_item, :any, default: &Function.identity/1
  attr :meta, :any, default: nil
  attr :path, :string, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :hide_on, :atom
    attr :field, :atom
  end

  attr :action_hide_on, :atom, default: nil
  attr :header_border, :boolean, default: true
  attr :bold_first, :boolean, default: true
  attr :show_header, :boolean, default: true
  slot :action

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="px-4 sm:overflow-visible sm:px-0">
      <table class={["w-full", @show_header && "mt-11"]}>
        <thead :if={@show_header} class="text-sm text-left leading-6 text-zinc-500 dark:text-zinc-400">
          <tr>
            <th
              :for={col <- @col}
              class={[
                "p-0 pr-6 pb-4 font-normal",
                col[:hide_on] && "hidden #{col[:hide_on]}:table-cell"
              ]}
            >
              <%= if col[:field] && @meta && @path do %>
                <.sort_link field={col[:field]} label={col[:label]} meta={@meta} path={@path} />
              <% else %>
                {col[:label]}
              <% end %>
            </th>
            <th
              :if={@action != []}
              class={["relative p-0 pb-4", @action_hide_on && "hidden #{@action_hide_on}:table-cell"]}
            >
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class={[
            "relative divide-y divide-zinc-100 dark:divide-zinc-700 text-sm leading-6",
            @header_border && "border-t border-zinc-200 dark:border-zinc-700"
          ]}
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="group hover:bg-zinc-50 dark:hover:bg-zinc-800"
          >
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              class={[
                "relative p-0",
                @row_click && "hover:cursor-pointer",
                col[:hide_on] && "hidden #{col[:hide_on]}:table-cell"
              ]}
            >
              <div class="block py-4 pr-6">
                <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-zinc-50 dark:group-hover:bg-zinc-800" />
                <span class={["relative", @bold_first && i == 0 && "font-semibold"]}>
                  {render_slot(col, @row_item.(row))}
                </span>
              </div>
            </td>
            <td
              :if={@action != []}
              class={["relative w-14 p-0", @action_hide_on && "hidden #{@action_hide_on}:table-cell"]}
            >
              <div class="relative whitespace-nowrap py-4 text-right text-sm font-medium">
                <span class="absolute -inset-y-px -right-4 left-0 group-hover:bg-zinc-50 dark:group-hover:bg-zinc-800" />
                <span
                  :for={action <- @action}
                  class="relative ml-4 font-semibold leading-6 hover:text-zinc-700 dark:hover:text-zinc-300"
                >
                  {render_slot(action, @row_item.(row))}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :meta, Flop.Meta, required: true
  attr :path, :string, required: true

  defp sort_link(assigns) do
    flop = assigns.meta.flop
    current_field = List.first(flop.order_by || [])
    current_dir = List.first(flop.order_directions || [])

    indicator =
      if current_field == assigns.field do
        case current_dir do
          :asc -> " \u25B4"
          :asc_nulls_first -> " \u25B4"
          :asc_nulls_last -> " \u25B4"
          _ -> " \u25BE"
        end
      end

    new_flop = Flop.push_order(flop, assigns.field)
    href = Flop.Phoenix.build_path(assigns.path, new_flop)

    assigns = assign(assigns, indicator: indicator, href: href)

    ~H"""
    <.link
      patch={@href}
      class="group inline-flex items-center hover:text-zinc-700 dark:hover:text-zinc-300"
    >
      {@label}<span :if={@indicator} class="ml-1">{@indicator}</span>
    </.link>
    """
  end

  attr :meta, Flop.Meta, required: true
  attr :path, :string, default: nil

  def pagination(assigns) do
    ~H"""
    <Flop.Phoenix.pagination
      meta={@meta}
      path={@path}
      class="flex items-center justify-center gap-1 mt-6"
      page_list_attrs={[class: "order-2 flex items-center gap-1"]}
      page_list_item_attrs={[class: "contents"]}
      page_link_attrs={[
        class:
          "inline-flex items-center justify-center rounded-md px-3 py-1.5 text-sm font-medium text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition"
      ]}
      current_page_link_attrs={[
        class:
          "inline-flex items-center justify-center rounded-md px-3 py-1.5 text-sm font-medium bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
      ]}
      disabled_link_attrs={[
        class: "opacity-40 pointer-events-none"
      ]}
    >
      <:previous attrs={[
        class:
          "order-1 inline-flex items-center justify-center rounded-md px-3 py-1.5 text-sm font-medium text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition"
      ]}>
        <svg class="w-4 h-4 mr-1" viewBox="0 0 20 20" fill="currentColor">
          <path
            fill-rule="evenodd"
            d="M12.79 5.23a.75.75 0 01-.02 1.06L8.832 10l3.938 3.71a.75.75 0 11-1.04 1.08l-4.5-4.25a.75.75 0 010-1.08l4.5-4.25a.75.75 0 011.06.02z"
            clip-rule="evenodd"
          />
        </svg>
        Prev
      </:previous>
      <:next attrs={[
        class:
          "order-3 inline-flex items-center justify-center rounded-md px-3 py-1.5 text-sm font-medium text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition"
      ]}>
        Next
        <svg class="w-4 h-4 ml-1" viewBox="0 0 20 20" fill="currentColor">
          <path
            fill-rule="evenodd"
            d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z"
            clip-rule="evenodd"
          />
        </svg>
      </:next>
      <:ellipsis>
        <span class="inline-flex items-center justify-center px-2 py-1.5 text-sm text-zinc-400 dark:text-zinc-500">
          &hellip;
        </span>
      </:ellipsis>
    </Flop.Phoenix.pagination>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  def detail_field(assigns) do
    ~H"""
    <div>
      <p class="text-sm text-zinc-500 dark:text-zinc-400">{@label}</p>
      <div class="mt-1 text-sm text-zinc-900 dark:text-zinc-200">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :empty_message, :string, default: nil
  attr :items, :list, required: true
  slot :actions
  slot :inner_block, required: true

  def card_section(assigns) do
    ~H"""
    <section>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-200">{@title}</h2>
        <div :if={@actions != []} class="flex items-center space-x-2">
          {render_slot(@actions)}
        </div>
      </div>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {render_slot(@inner_block)}
      </div>
      <p
        :if={@items == [] && @empty_message}
        class="text-sm text-zinc-500 dark:text-zinc-400 italic"
      >
        {@empty_message}
      </p>
    </section>
    """
  end

  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="block rounded-lg border border-zinc-200/50 dark:border-zinc-700/50 p-4 hover:bg-zinc-50 dark:hover:bg-zinc-800 transition"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :state, :boolean, required: true

  def online(assigns) do
    ~H"""
    <svg class="w-4 h-4" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
      <circle
        cx="12"
        cy="12"
        r="10"
        class={
          if @state,
            do: "fill-green-500",
            else: "fill-none stroke-gray-300 stroke-2"
        }
      />
      <line
        :if={not @state}
        x1="4"
        y1="20"
        x2="20"
        y2="4"
        class="stroke-gray-300 stroke-2"
      />
    </svg>
    """
  end

  attr :state, :atom, required: true
  attr :result, :atom, default: nil

  def deployment_status(assigns) do
    ~H"""
    <%= case @state do %>
      <% :created -> %>
        <span class="inline-flex items-center gap-1.5 text-sm text-zinc-500 dark:text-zinc-400">
          <span class="relative flex h-2.5 w-2.5">
            <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-zinc-400 opacity-75" />
            <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-zinc-400" />
          </span>
          Created
        </span>
      <% :dispatched -> %>
        <span class="inline-flex items-center gap-1.5 text-sm text-blue-600 dark:text-blue-400">
          <span class="relative flex h-2.5 w-2.5">
            <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-blue-500 opacity-75" />
            <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-blue-500" />
          </span>
          Dispatched
        </span>
      <% :acknowledged -> %>
        <span class="inline-flex items-center gap-1.5 text-sm text-blue-600 dark:text-blue-400">
          <span class="relative flex h-2.5 w-2.5">
            <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-blue-500 opacity-75" />
            <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-blue-500" />
          </span>
          Acknowledged
        </span>
      <% :completed -> %>
        <.result result={@result} />
      <% :stale -> %>
        <span class="inline-flex items-center gap-1.5 text-sm text-amber-600 dark:text-amber-400">
          <span class="relative flex h-2.5 w-2.5">
            <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-amber-500" />
          </span>
          Stale
        </span>
    <% end %>
    """
  end

  attr :result, :string, required: true

  def result(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
      <%= cond do %>
        <% @result == :success -> %>
          <path
            d="M5 12l5 5L20 7"
            class="fill-none stroke-green-500 stroke-2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        <% is_nil(@result) -> %>
          <line
            x1="6"
            y1="12"
            x2="18"
            y2="12"
            class="stroke-gray-400 stroke-2"
            stroke-linecap="round"
          />
        <% true -> %>
          <line
            x1="6"
            y1="6"
            x2="18"
            y2="18"
            class="stroke-red-500 stroke-2"
            stroke-linecap="round"
          />
          <line
            x1="18"
            y1="6"
            x2="6"
            y2="18"
            class="stroke-red-500 stroke-2"
            stroke-linecap="round"
          />
      <% end %>
    </svg>
    """
  end

  attr :datetime, DateTime, default: nil
  attr :user_timezone, :string, required: true

  def local_datetime(assigns) do
    local_dt =
      if assigns.datetime do
        assigns.datetime
        |> DateTime.shift_zone!(assigns.user_timezone)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
      else
        "-"
      end

    assigns = assign(assigns, :local_dt, local_dt)

    ~H"""
    <span>{@local_dt}</span>
    """
  end

  attr :subscription_sid, :string, required: true
  attr :deployable, :boolean, default: false
  attr :deploying, :boolean, default: false
  attr :deploy_error, :string, default: nil

  def deploy_button(assigns) do
    ~H"""
    <div class="inline-flex items-center gap-2">
      <.button
        :if={@deployable}
        variant={:secondary}
        type="button"
        phx-click="deploy_subscription"
        phx-value-subscription_sid={@subscription_sid}
        phx-disable-with="Deploying..."
        disabled={@deploying}
      >
        Deploy
      </.button>
      <span
        :if={@deploy_error}
        class="text-sm text-red-600 dark:text-red-400"
      >
        {@deploy_error}
      </span>
    </div>
    """
  end

  attr :id, :string, required: true

  def uuid(assigns) do
    id = assigns.id |> String.split("-") |> List.last()

    assigns =
      assign(assigns, :id, id)

    ~H"""
    <span title={@__given__.id}>{@id}</span>
    """
  end
end
