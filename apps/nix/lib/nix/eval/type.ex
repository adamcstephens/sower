defmodule Nix.Eval.Type do
  @moduledoc """
  Type detection for Nix evaluation targets.

  Determines whether a target should be evaluated as a flake or path-based expression.
  """

  @type t :: :flake | :path

  @doc """
  Detect the evaluation type for a given path.

  Returns `:flake` or `:path` based on the path characteristics:
  - Contains `#` → flake (has attribute fragment)
  - Contains `://` → flake (URL scheme)
  - Ends with `.nix` → path
  - Has `flake.nix` in directory → flake
  - Has `default.nix` in directory → path
  - Otherwise → `{:error, :unknown_type}`

  ## Examples

      iex> Nix.Eval.Type.detect(".")
      :flake  # if flake.nix exists

      iex> Nix.Eval.Type.detect(".#packages")
      :flake

      iex> Nix.Eval.Type.detect("github:NixOS/nixpkgs")
      :flake

      iex> Nix.Eval.Type.detect("./default.nix")
      :path
  """
  def detect(path) do
    cond do
      String.match?(path, ~r{#}) ->
        :flake

      String.match?(path, ~r{://}) ->
        :flake

      String.ends_with?(path, ".nix") ->
        :path

      File.exists?(Path.expand("flake.nix", path)) ->
        :flake

      File.exists?(Path.expand("default.nix", path)) ->
        :path

      true ->
        {:error, :unknown_type}
    end
  end

  @doc """
  Check if a type is valid.

  ## Examples

      iex> Nix.Eval.Type.valid?(:flake)
      true

      iex> Nix.Eval.Type.valid?(:path)
      true

      iex> Nix.Eval.Type.valid?(:invalid)
      false
  """
  def valid?(:flake), do: true
  def valid?(:path), do: true
  def valid?(_), do: false
end
