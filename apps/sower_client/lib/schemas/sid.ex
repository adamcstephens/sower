defmodule SowerClient.Schemas.Sid do
  use Ecto.Type

  @type t :: :string
  def type, do: :string
  def cast(value), do: {:ok, value}
  def load(value), do: {:ok, value}
  def dump(value) when is_binary(value), do: {:ok, value}
  def dump(_), do: :error

  def autogenerate, do: generate()

  def generate, do: Cuid2Ex.create()
  def generate(prefix), do: "#{prefix}_#{generate()}"
end
