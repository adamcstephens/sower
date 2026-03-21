defmodule SowerCli.Cache do
  @moduledoc """
  Cache URL parsing and backend selection.
  """

  @doc """
  Parse a cache URL and return the appropriate backend module and config.

  ## Examples

      iex> SowerCli.Cache.parse_url("attic://myserver:mycache")
      {:ok, {Nix.Cache.Attic, %{cache: "myserver:mycache"}}}

      iex> SowerCli.Cache.parse_url("ssh://user@host")
      {:ok, {Nix.Cache.NixCopy, %{destination: "ssh://user@host"}}}
  """
  def parse_url("niks3://" <> _rest) do
    {:ok, {Nix.Cache.Niks3, %{}}}
  end

  def parse_url("attic://" <> rest) do
    {:ok, {Nix.Cache.Attic, %{cache: rest}}}
  end

  def parse_url(url) do
    {:ok, {Nix.Cache.NixCopy, %{destination: url}}}
  end
end
