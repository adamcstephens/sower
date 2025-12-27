defmodule Nix.Eval.Request do
  @moduledoc """
  Represents a Nix evaluation request.

  Supports both flake and path-based evaluation targets.
  """

  use TypedStruct

  require Logger

  alias Nix.Eval.Type

  typedstruct do
    field :id, String.t()
    field :type, :flake | :path
    field :path, String.t()
    field :attr, String.t() | nil, default: nil
    field :root_id, String.t() | nil, default: nil
  end

  @doc """
  Parse a path into an evaluation request.

  ## Options
  - `:attr` - Attribute path to evaluate (e.g., "packages.x86_64-linux")
  - `:type` - Explicit type (:flake, :path, or :auto for auto-detection). Default: :auto

  ## Examples

      iex> Nix.Eval.Request.parse(".")
      %Nix.Eval.Request{type: :flake, path: ".", ...}

      iex> Nix.Eval.Request.parse("./default.nix", type: :path)
      %Nix.Eval.Request{type: :path, path: "/absolute/path/default.nix", ...}
  """
  def parse(path, opts \\ [])

  def parse(path, opts) when is_list(opts) do
    attr = Keyword.get(opts, :attr)
    explicit_type = Keyword.get(opts, :type, :auto)

    type = resolve_type(path, explicit_type)
    {parsed_path, attribute} = parse_path(type, path, attr)

    %__MODULE__{
      id: new_id(),
      type: type,
      path: parsed_path,
      attr: attribute
    }
  end

  # Backwards compatibility: parse(path, attr) where attr is a string
  def parse(path, attr) when is_binary(attr) or is_nil(attr) do
    parse(path, attr: attr)
  end

  def new_id, do: "eval_#{Cuid2Ex.create()}"

  defp resolve_type(path, :auto) do
    case Type.detect(path) do
      {:error, :unknown_type} ->
        Logger.error(msg: "Failed to detect type", path: path)
        raise RuntimeError

      type ->
        type
    end
  end

  defp resolve_type(_path, type) when type in [:flake, :path], do: type

  def parse_path(:flake, path, nil) do
    case String.split(path, "#") do
      [flake] -> {flake, nil}
      [flake, ""] -> {flake, nil}
      [flake, attr] -> {flake, attr}
    end
  end

  def parse_path(:path, path, attr), do: {Path.expand(path), attr}

  def parse_path(_, path, attr), do: {path, attr}

  def to_flake_uri(%{type: :flake, path: path, attr: attr}), do: "#{path}##{attr}"

  def to_import(%{type: :path, path: path, attr: nil}), do: "import #{path} {}"
  def to_import(%{type: :path, path: path, attr: attr}), do: "(import #{path} {}).#{attr}"
end
