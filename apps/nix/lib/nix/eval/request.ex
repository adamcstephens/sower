defmodule Nix.Eval.Request do
  use TypedStruct

  require Logger

  typedstruct do
    field :id, String.t()
    field :type, :flake | :path
    field :path, String.t()
    field :attr, String.t() | nil, default: nil
    field :root_id, String.t() | nil, default: nil
  end

  def parse(path, attr \\ nil) do
    type = detect_type(path)

    {path, attribute} = parse_path(type, path, attr)

    %__MODULE__{
      id: new_id(),
      type: type,
      path: path,
      attr: attribute
    }
  end

  def new_id(), do: "eval_#{Cuid2Ex.create()}"

  def detect_type(path) do
    cond do
      String.match?(path, ~r{#}) ->
        :flake

      String.match?(path, ~r{://}) ->
        :flake

      String.ends_with?(path, ".nix") ->
        :path

      File.exists?(Path.expand("flake.nix", path)) ->
        :flake

      File.exists?(Path.expand("flake.nix", path)) ->
        :path

      true ->
        Logger.error(msg: "Failed to detect type", path: path)
        raise RuntimeError
    end
  end

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
