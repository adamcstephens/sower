defmodule SowerWeb.ClientChannel do
  use Phoenix.Channel

  require Logger

  def join("client:lobby", _message, %{assigns: %{sid: sid}} = socket) do
    Logger.debug(msg: "Channel topic joined", topic: "client:all", sid: sid)
    {:ok, %{sid: sid}, socket}
  end

  def join("client:" <> topic_sid = topic, _params, %{assigns: %{sid: sid}} = socket) do
    Logger.debug(msg: "Channel topic joined", topic: topic, sid: sid)

    if sid == topic_sid do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("ping", _, %{assigns: %{sid: sid}} = socket) do
    Logger.debug(msg: "Received ping, ponging", sid: sid)
    {:reply, {:ok, :pong}, socket}
  end

  def handle_in("pong", %{"ref" => _ref}, %{assigns: %{sid: _sid}} = socket) do
    {:reply, :ok, socket}
  end

  def handle_in("agent:hello", payload, socket) do
    SowerClient.Agent.new(payload) |> dbg()
    {:reply, {:ok, "got it"}, socket}
  end

  def handle_info(:ping, %Phoenix.Socket{assigns: %{sid: sid}} = socket) do
    ref = Sower.Schema.Sid.generate()
    Logger.debug(msg: "Sending ping", sid: sid, ref: ref)
    push(socket, "ping", %{ref: ref})
    {:noreply, socket}
  end

  # def handle_in(
  #       "seed:submit",
  #       %{
  #         "name" => name,
  #         "seed_type" => seed_type,
  #         "out_path" => out_path
  #       } = _seed,
  #       socket
  #     ) do
  #   case Sower.Seed.submit(%{name: name, seed_type: seed_type, out_path: out_path}) do
  #     {:ok, %Sower.Seed{} = seed} ->
  #       {:reply, {:ok, %{seed_id: seed.id}}, socket}
  #
  #     {:error, _err} ->
  #       {:reply, {:error, "failed to submit"}, socket}
  #   end
  # end
end
