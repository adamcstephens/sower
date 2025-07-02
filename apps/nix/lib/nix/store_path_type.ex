defmodule Nix.StorePathType do
  @doc "read the type's state"
  @callback get_state() :: __MODULE__ | list(__MODULE__) | nil
end
