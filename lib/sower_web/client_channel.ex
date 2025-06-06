defmodule SowerWeb.ClientChannel do
  use Phoenix.Channel

  require Logger

  def join("client:lobby", _message, socket = %{assigns: %{sid: sid}}) do
    Logger.debug(msg: "Channel topic joined", topic: "client:all", sid: sid)
    {:ok, %{sid: sid}, socket}
  end

  def join("client:" <> topic_sid = topic, _params, socket = %{assigns: %{sid: sid}}) do
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
