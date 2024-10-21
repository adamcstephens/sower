defmodule SowerWeb.Settings.AccessTokenLive.Index do
  use SowerWeb, :live_view

  alias Sower.Accounts
  alias Sower.Accounts.AccessToken

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     stream(
       socket,
       :access_tokens,
       Accounts.list_user_access_tokens(socket.assigns.current_user.id)
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Access token")
    |> assign(:access_token, Accounts.AccessToken.get!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New access token")
    |> assign(:access_token, %AccessToken{
      expires_at: Date.utc_today() |> Date.add(1)
    })
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Access-tokens")
    |> assign(:access_token, nil)
  end

  @impl true
  def handle_info(
        {SowerWeb.Settings.AccessTokenLive.FormComponent, {:saved, access_token}},
        socket
      ) do
    {:noreply, stream_insert(socket, :access_tokens, access_token)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    access_token = Accounts.AccessToken.get!(id)
    {:ok, _} = Accounts.AccessToken.delete(access_token)

    {:noreply, stream_delete(socket, :access_tokens, access_token)}
  end
end
