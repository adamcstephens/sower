defmodule SowerWeb.SowerComponents do
  use Phoenix.Component

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

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil

  attr :row_item, :any, default: &Function.identity/1

  slot :col, required: true do
    attr :label, :string
  end

  def responsive_table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="sm:overflow-visible sm:px-0">
      <table class="responsive-table w-full mt-11">
        <thead class="text-sm text-left leading-6 text-zinc-500 dark:text-zinc-400">
          <tr>
            <th :for={col <- @col} class="p-0 pr-6 pb-4 font-normal">{col[:label]}</th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class="relative divide-y divide-zinc-200/50 dark:divide-zinc-700/50 border-t border-zinc-200/50 dark:border-zinc-700/50 text-sm leading-6"
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="group hover:bg-zinc-50 dark:hover:bg-zinc-800"
          >
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              data-label={col[:label]}
              class={["relative p-0", @row_click && "hover:cursor-pointer"]}
            >
              <div class="block py-4 pr-6">
                <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-zinc-50 dark:group-hover:bg-zinc-800 sm:block hidden" />
                <span class={["relative", i == 0 && "font-semibold"]}>
                  {render_slot(col, @row_item.(row))}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
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
