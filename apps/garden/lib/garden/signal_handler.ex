defmodule Garden.SignalHandler do
  @moduledoc """
  Translates OS signals into garden lifecycle events.

  - `SIGHUP` triggers `Garden.request_reload/0`, used by systemd `ExecReload`.
  - `SIGTERM` keeps the BEAM default, which performs an orderly `init:stop/0`.
  """

  @behaviour :gen_event

  require Logger

  def attach do
    :os.set_signal(:sighup, :handle)
    :gen_event.add_handler(:erl_signal_server, __MODULE__, [])
  end

  @impl :gen_event
  def init(_args), do: {:ok, %{}}

  @impl :gen_event
  def handle_event(:sighup, state) do
    Logger.info(msg: "Received SIGHUP, requesting reload")
    Garden.request_reload()
    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def handle_info(_msg, state), do: {:ok, state}

  @impl :gen_event
  def terminate(_reason, _state), do: :ok

  @impl :gen_event
  def code_change(_old, state, _extra), do: {:ok, state}
end
