defmodule VMManager.Serialization do
  @moduledoc false

  def serializable?(value) when is_atom(value) or is_bitstring(value) or is_number(value),
    do: true

  def serializable?([]), do: true
  def serializable?([head | tail]), do: serializable?(head) and serializable?(tail)

  def serializable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  def serializable?(value) when is_map(value),
    do:
      Enum.all?(Map.to_list(value), fn {key, item} ->
        serializable?(key) and serializable?(item)
      end)

  def serializable?(_), do: false
end
