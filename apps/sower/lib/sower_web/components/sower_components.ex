defmodule SowerWeb.SowerComponents do
  use Phoenix.Component

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
