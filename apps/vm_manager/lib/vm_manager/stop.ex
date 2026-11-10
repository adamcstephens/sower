defmodule VMManager.Stop do
  @moduledoc """
  Stop policy shared by the manager, execution controller and resource guard.

  Ordinary stops request guest ACPI shutdown and wait up to
  `guest_shutdown_timeout_ms` before authorized force teardown. Force stops skip
  the guest request and wait. Cleanup certification is required in either mode.
  """
  use TypedStruct

  typedstruct do
    field :mode, :graceful | :force, default: :graceful
    field :guest_shutdown_timeout_ms, non_neg_integer(), default: 10_000
  end

  def new(options) when is_list(options) do
    mode = Keyword.get(options, :mode, :graceful)
    timeout = Keyword.get(options, :guest_shutdown_timeout_ms, 10_000)

    if mode in [:graceful, :force] and is_integer(timeout) and timeout >= 0 do
      {:ok, %__MODULE__{mode: mode, guest_shutdown_timeout_ms: timeout}}
    else
      {:error, :invalid_stop_policy}
    end
  end
end
