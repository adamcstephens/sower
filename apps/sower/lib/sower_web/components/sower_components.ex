defmodule SowerWeb.SowerComponents do
  use Phoenix.Component

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
