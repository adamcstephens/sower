defmodule Nix.Store do
  require Logger

  def realize(path) do
    Logger.debug(msg: "Realizing path", path: path)

    case System.cmd("nix-store", ["--realize", path], into: [], lines: 1024) do
      {lines, 0} -> {:ok, lines}
      {_, code} -> {:error, code}
    end
  end
end
