defmodule Nix do
  def narhash_from_path(path) do
    path |> Path.split() |> List.last() |> String.split("-") |> List.first()
  end
end
