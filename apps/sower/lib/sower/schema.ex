defmodule Sower.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema

      # defaults
      @primary_key {:id, :id, autogenerate: true}
      @foreign_key_type :id
    end
  end
end
