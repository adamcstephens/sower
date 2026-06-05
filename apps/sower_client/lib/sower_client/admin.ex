defmodule SowerClient.Admin do
  @moduledoc """
  Garden admin socket protocol (CLI <-> garden).

  Newline-delimited compact JSON, **adjacently tagged**: the wire envelope is
  `{v, id, kind, payload}` where `kind` selects the typed command struct and
  `payload` carries its fields (omitted for the field-less commands). `kind` is
  derived from the command struct's module, not stored as a field on it.

  These types are CLI<->garden only. The command/reply schemas are registered in
  `SowerClient.spec()` so the garden can `cast/1` them, but they are excluded
  from `@server_pushed_schema_titles` (not server broadcasts). The Rust CLI
  hand-writes the matching serde, so they never need to reach `openapi.json` via
  the server router.
  """

  use TypedStruct

  alias SowerClient.Admin.Deploy
  alias SowerClient.Admin.Reload
  alias SowerClient.Admin.Status

  @kinds %{
    deploy: Deploy,
    reload: Reload,
    status: Status
  }

  typedstruct module: Request do
    field(:v, integer(), default: 1)
    field(:id, String.t())
    field(:message, struct(), enforce: true)
  end

  @doc """
  Decode a wire envelope map into a `Request` carrying its typed command struct.

  Returns `{:error, {:unknown_kind, kind}}` for an unrecognized `kind`,
  `{:error, :missing_kind}` when absent, or the cast error for a bad payload.
  """
  def decode_request(%{"kind" => kind} = map) when is_binary(kind) do
    with {:ok, module} <- module_for_kind(kind),
         {:ok, message} <- module.cast(Map.get(map, "payload") || %{}) do
      {:ok, %Request{v: Map.get(map, "v", 1), id: Map.get(map, "id"), message: message}}
    else
      {:error, _} = err -> err
    end
  end

  def decode_request(_), do: {:error, :missing_kind}

  defp module_for_kind(kind) do
    case Map.fetch(@kinds, String.to_existing_atom(kind)) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_kind, kind}}
    end
  rescue
    # An unknown kind has no existing atom; treat it the same as an unknown one.
    ArgumentError -> {:error, {:unknown_kind, kind}}
  end
end
