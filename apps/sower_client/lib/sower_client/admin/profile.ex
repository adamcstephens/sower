defmodule SowerClient.Admin.Profile do
  @moduledoc """
  Named package/devshell profile commands over the local Garden admin socket.

  Listing and inspection use durable local inventory without server connectivity.
  Generation IDs are stable opaque strings, not native Nix generation numbers.
  Uninstall previews by default; pinned generations require separate unpin commands.
  Stage retains the subscription deployment and policy boundary.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminProfile",
    type: :object,
    properties: %{
      action: %Schema{
        type: :string,
        enum: [:list, :inspect, :stage, :select, :rollback, :pin, :unpin, :discard, :uninstall]
      },
      profile_name: %Schema{type: :string, nullable: true},
      generation_id: %Schema{type: :string, nullable: true},
      seed_sid: %Schema{type: :string, nullable: true},
      subscription_sid: %Schema{type: :string, nullable: true},
      preview: %Schema{type: :boolean, default: true}
    },
    required: [:action]
  })
end
