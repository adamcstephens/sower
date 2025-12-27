defmodule SowerCli.Cache do
  @moduledoc """
  Cache URL parsing and backend selection.

  Supports auto-detection of cache backends from URL prefixes:
  - `attic://server:cache` -> Nix.Cache.Attic
  - `ssh://`, `s3://`, `file://`, `https://` -> Nix.Cache.NixCopy
  """

  @doc """
  Parse a cache URL and return the appropriate backend module and config.

  ## Examples

      iex> SowerCli.Cache.parse_url("attic://myserver:mycache")
      {:ok, {Nix.Cache.Attic, %{cache: "myserver:mycache"}}}

      iex> SowerCli.Cache.parse_url("ssh://user@host")
      {:ok, {Nix.Cache.NixCopy, %{destination: "ssh://user@host"}}}

      iex> SowerCli.Cache.parse_url("invalid")
      {:error, "Unknown cache URL format: invalid"}
  """
  def parse_url("attic://" <> rest) do
    {:ok, {Nix.Cache.Attic, %{cache: rest}}}
  end

  def parse_url("ssh://" <> _ = url) do
    {:ok, {Nix.Cache.NixCopy, %{destination: url}}}
  end

  def parse_url("s3://" <> _ = url) do
    {:ok, {Nix.Cache.NixCopy, %{destination: url}}}
  end

  def parse_url("file://" <> _ = url) do
    {:ok, {Nix.Cache.NixCopy, %{destination: url}}}
  end

  def parse_url("https://" <> _ = url) do
    {:ok, {Nix.Cache.NixCopy, %{destination: url}}}
  end

  def parse_url("http://" <> _ = url) do
    {:ok, {Nix.Cache.NixCopy, %{destination: url}}}
  end

  def parse_url(url) do
    {:error, "Unknown cache URL format: #{url}. Expected attic://, ssh://, s3://, file://, or https://"}
  end
end
