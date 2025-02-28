defmodule Sower.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema

      # defaults
      @primary_key {:id, :id, autogenerate: true}
      @foreign_key_type :id
    end
  end

  defmodule Sid do
    use Ecto.Type

    @type t :: :string
    def type, do: :string
    def cast(value), do: {:ok, value}
    def load(value), do: {:ok, value}
    def dump(value) when is_binary(value), do: {:ok, value}
    def dump(_), do: :error

    def autogenerate, do: generate()

    def generate, do: Cuid2Ex.create()
  end

  defmodule Nix.StorePathDigest do
    use Ecto.Type

    @type t :: :string
    def type, do: :string
    def cast(value), do: {:ok, value}
    def load(value), do: {:ok, value}
    def dump(value) when is_binary(value), do: {:ok, value}
    def dump(_), do: :error
  end
end
