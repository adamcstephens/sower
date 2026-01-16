defmodule Sower.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema

      # defaults
      @primary_key {:id, :id, autogenerate: true}
      @foreign_key_type :id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
