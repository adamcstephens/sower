defmodule SowerWeb.SowerComponents do
  use Phoenix.Component

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
