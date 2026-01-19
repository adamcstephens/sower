defmodule SowerAgent do
  @moduledoc """
  Public API for the SowerAgent application.
  """

  alias SowerAgent.Client

  @doc """
  Request a reload of the agent service.

  This is a fire-and-forget operation that sets a flag. The reload will be
  executed at the end of the current deployment (if one is in progress) or
  can be checked manually via `take_pending_reload/0`.

  Intended to be called via RPC by ExecReload:

      sower-agent rpc "SowerAgent.request_reload()"

  """
  def request_reload() do
    :persistent_term.put(:sower_pending_reload, true)
    send(SowerAgent.Client, :check_pending_reload)
    :ok
  end

  @doc """
  Atomically checks and clears the pending reload flag.
  """
  def take_pending_reload() do
    case :persistent_term.get(:sower_pending_reload, false) do
      true ->
        :persistent_term.erase(:sower_pending_reload)
        true

      false ->
        false
    end
  end

  defdelegate reload_agent_service, to: Client
end
