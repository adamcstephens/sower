defmodule Nix do
  defdelegate eval(target, opts \\ []), to: Nix.Eval, as: :run

  def narhash_from_path(path) do
    path |> Path.split() |> List.last() |> String.split("-") |> List.first()
  end
end
