defmodule Sower.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      @primary_key {:id, UUIDv7, autogenerate: true}

      @foreign_key_type UUIDv7
    end
  end
end
