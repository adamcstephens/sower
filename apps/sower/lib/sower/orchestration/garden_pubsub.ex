defmodule Sower.Orchestration.GardenPubSub do
  @moduledoc """
  PubSub broadcasting for garden reporting events.
  """

  alias Sower.Orchestration.Garden
  require Logger

  @doc """
  Broadcasts when a garden's reported metadata (e.g., version) changes.
  """
  def broadcast_garden_change(%Garden{} = garden, event \\ :updated) do
    broadcast("garden:view:#{garden.sid}", {:garden, event, garden})
    {:ok, garden}
  end

  @doc """
  Broadcasts when a garden's seed generations report has been ingested.
  """
  def broadcast_seed_generations_change(%Garden{} = garden, event \\ :updated) do
    broadcast("garden:view:#{garden.sid}", {:garden_seed_generations, event, garden})
    {:ok, garden}
  end

  defp broadcast(topic, message) do
    case Phoenix.PubSub.broadcast(Sower.PubSub, topic, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          msg: "Failed to broadcast garden change",
          topic: topic,
          error: inspect(reason)
        )

        :ok
    end
  end
end
