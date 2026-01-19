defmodule SowerWeb.Settings.AccessTokenLive.Show do
  use SowerWeb, :live_view

  alias Sower.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    case Accounts.AccessToken.get_sid(sid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Access token not found")
         |> redirect(to: ~p"/settings/access-tokens")}

      access_token ->
        {:noreply,
         socket
         |> assign(:page_title, page_title(socket.assigns.live_action))
         |> assign(:access_token, access_token)}
    end
  end

  defp page_title(:show), do: "Show Access token"
  defp page_title(:edit), do: "Edit Access token"

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    access_token = Accounts.AccessToken.get!(id)
    {:ok, _} = Accounts.AccessToken.delete(access_token)

    {:noreply, push_navigate(socket, to: ~p"/settings/access-tokens")}
  end

  attr :flash, :map, required: true

  def flash_token(assigns) do
    ~H"""
    <%= if @flash["token"] do %>
      <div class="box-border bg-blue-700 m-6 p-4 rounded">
        <div>Copy this token now! It will not be stored nor shown again.</div>
        <div class="pt-6 text-balance break-all">{@flash["token"]}</div>
      </div>
    <% end %>
    """
  end
end
