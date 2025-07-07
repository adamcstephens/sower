defmodule SowerClient.Schemas.StorePath do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "StorePath",
    description: "A store path is a Nix store path that can by installed by a client",
    type: :object,
    properties: %{
      path: %Schema{
        type: :string,
        description: "Nix store path"
      },
      path_digest: %Schema{
        type: :string,
        description: "id of the store path",
        readOnly: true
      }
    },
    required: ~w(path)a,
    example: %{
      "path_digest" => "examplehxpf8d7x5ys5p9v0z9x587hs1",
      "path" => "/nix/store/examplehxpf8d7x5ys5p9v0z9x587hs1-..."
    }
  })
end
