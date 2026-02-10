defmodule SowerClient.Orchestration.DeploymentProfile do
  use SowerClient.Schema

  @reboot_policies ["never", "when-required", "always"]

  OpenApiSpex.schema(%{
    title: "DeploymentProfile",
    type: :object,
    properties: %{
      activation_args: %Schema{
        type: :array,
        items: %Schema{type: :string},
        default: [],
        description:
          "Arguments to pass to activation script. For example [`boot`] for NixOS seeds to apply in boot mode."
      },
      reboot_policy: %Schema{
        type: :string,
        description: "Whether deployment can trigger automated reboots.",
        enum: @reboot_policies,
        default: "never",
        example: "when-required"
      }
    },
    required: []
  })
end
