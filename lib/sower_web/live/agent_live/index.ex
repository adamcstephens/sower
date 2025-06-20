defmodule SowerWeb.AgentLive.Index do
  use SowerWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias Sower.Orchestration
  alias Sower.Orchestration.Agent
  alias SowerWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "agent:presence")
    end

    {:ok,
     stream(socket, :agents, Orchestration.list_agents())
     |> assign(:agent_presence, Presence.list("agent:presence"))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"sid" => sid}) do
    socket
    |> assign(:page_title, "Edit Agent")
    |> assign(:agent, Orchestration.get_agent_sid!(sid))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Agent")
    |> assign(:agent, %Agent{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Agents")
    |> assign(:agent, nil)
  end

  @impl true
  def handle_info({SowerWeb.AgentLive.FormComponent, {:saved, agent}}, socket) do
    {:noreply, stream_insert(socket, :agents, agent)}
  end

  @impl true
  def handle_info(%Broadcast{topic: "agent:presence", event: "presence_diff"}, socket) do
    # update the presence list, then touch the stream to force a table refresh
    socket =
      socket
      |> assign(:agent_presence, Presence.list("agent:presence"))
      |> stream(:agents, Orchestration.list_agents())

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    agent = Orchestration.get_agent!(id)
    {:ok, _} = Orchestration.delete_agent(agent)

    {:noreply, stream_delete(socket, :agents, agent)}
  end
end
