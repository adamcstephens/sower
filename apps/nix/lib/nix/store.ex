defmodule Nix.Store do
  def realize(path) do
    case System.cmd("nix-store", ["--realize", path], into: [], lines: 1024) do
      {lines, 0} -> {:ok, lines}
      {_, code} -> {:error, code}
    end
  end
end
