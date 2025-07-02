defmodule Nix.HomeManager do
  alias Nix.StorePathType
  @behaviour StorePathType

  @impl StorePathType
  def get_state() do
    "#{System.get_env("XDG_STATE_HOME")}/nix/profiles/home-manager"
    |> follow_link()
  end

  def follow_link(path) do
    parent = Path.dirname(path)

    case File.read_link(path) do
      {:ok, source} ->
        source = Path.absname(source, parent)

        case source |> Path.absname() |> File.lstat() |> dbg() do
          {:ok, %{type: :symlink}} -> follow_link(source)
          {:ok, _} -> {:ok, source}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end
end
