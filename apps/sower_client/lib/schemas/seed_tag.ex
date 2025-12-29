defmodule SowerClient.Schemas.SeedTag do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "SeedTag",
    description: "A tag associated with a seed",
    type: :object,
    properties: %{
      key: %Schema{
        type: :string,
        description: "Tag key"
      },
      value: %Schema{
        type: :string,
        description: "Tag value"
      }
    },
    required: [:key, :value],
    example: %{
      "key" => "environment",
      "value" => "production"
    }
  })

  def from_string(tag) when is_binary(tag) do
    [key, val] = String.split(tag, "=")

    %__MODULE__{
      key: key,
      value: val
    }
  end
end
