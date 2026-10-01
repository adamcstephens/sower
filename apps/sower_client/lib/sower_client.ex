defmodule SowerClient do
  # Schemas the server pushes TO gardens (broadcasts + replies).
  # Changes to these can break old gardens that haven't upgraded.
  # Used by contract evolution tests and baseline generation.
  @server_pushed_schema_titles [
    "Deployment",
    "OAuthCredentials",
    "SeedDeployment",
    "Seed",
    "SeedTag",
    "PresignedUploadReply",
    "PendingDeployment"
  ]

  def server_pushed_schema_titles, do: @server_pushed_schema_titles

  def spec() do
    %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{
        title: "SowerClient",
        version: to_string(Application.spec(:sower, :vsn))
      },
      paths: %{},
      components: %OpenApiSpex.Components{schemas: %{}}
    }
    |> OpenApiSpex.add_schemas([
      SowerClient.Admin.Deploy,
      SowerClient.Admin.Reload,
      SowerClient.Admin.Reregister,
      SowerClient.Admin.Status,
      SowerClient.Admin.StatusReport,
      SowerClient.Admin.Reply,
      SowerClient.GardenRegistration,
      SowerClient.Auth.OAuthCredentials,
      SowerClient.Auth.TokenInfo,
      SowerClient.Orchestration.GardenSeedGeneration,
      SowerClient.Orchestration.GardenSeedProfile,
      SowerClient.Orchestration.GardenSeedsReport,
      SowerClient.Orchestration.GardenReport,
      SowerClient.Orchestration.Deployment,
      SowerClient.Orchestration.DeploymentResult,
      SowerClient.Orchestration.DeploymentRequest,
      SowerClient.Orchestration.PendingDeployment,
      SowerClient.Orchestration.PendingDeploymentsRequest,
      SowerClient.Orchestration.DeploymentStatus,
      SowerClient.Orchestration.DeploymentInfo,
      SowerClient.Orchestration.DeploymentInfo.SeedInfo,
      SowerClient.Orchestration.DirectDeployment,
      SowerClient.Orchestration.SeedDeployment,
      SowerClient.Orchestration.SeedDeploymentResult,
      SowerClient.Orchestration.SeedDeploymentStatus,
      SowerClient.Orchestration.Subscription,
      SowerClient.Orchestration.Subscription.Policy,
      SowerClient.Orchestration.Subscription.Window,
      SowerClient.Orchestration.SubscriptionSync,
      SowerClient.Storage.PresignedUploadReply,
      SowerClient.Seed,
      SowerClient.SeedMeta,
      SowerClient.SeedManifest,
      SowerClient.SeedTag
    ])
    |> OpenApiSpex.resolve_schema_modules()
  end
end

defmodule SowerClient.SeedManifest do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "SeedManifest",
    description: "Version-1 manifest describing a built seed",
    type: :object,
    additionalProperties: false,
    "x-validate": __MODULE__.StrictTypes,
    properties: %{
      version: %Schema{type: :integer, enum: [1]},
      name: %Schema{type: :string, minLength: 1},
      seed_type: %Schema{
        type: :string,
        enum: ["nixos", "home-manager", "nix-darwin", "service"]
      },
      artifact: %Schema{
        type: :string,
        pattern: "^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/]+$"
      },
      tags: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string}
      }
    },
    required: [:version, :name, :seed_type, :artifact, :tags]
  })

  defmodule StrictTypes do
    @moduledoc false
    alias OpenApiSpex.Cast

    # OpenApiSpex normally coerces numeric strings and accepts atoms as strings.
    # Manifest files must retain the JSON types required by the Nix schema.
    def cast(%Cast{} = ctx) do
      case check_types(ctx) do
        :ok ->
          Cast.cast(%{ctx | schema: %{ctx.schema | "x-validate": nil}})

        {:error, _} = error ->
          error
      end
    end

    defp check_types(%Cast{value: value} = ctx) when is_map(value) do
      Enum.reduce_while(
        [version: :integer, name: :string, seed_type: :string, artifact: :string, tags: :object],
        :ok,
        fn {field, type}, :ok ->
          value = Map.get(ctx.value, Atom.to_string(field), Map.get(ctx.value, field))
          field_ctx = %{ctx | value: value, path: [field | ctx.path]}

          case check_type(field_ctx, type) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end
      )
    end

    defp check_types(%Cast{}), do: :ok

    # Missing and null fields are rejected by the standard required/null checks.
    defp check_type(%Cast{value: nil}, _type), do: :ok
    defp check_type(%Cast{value: value}, :integer) when is_integer(value), do: :ok
    defp check_type(%Cast{value: value}, :string) when is_binary(value), do: :ok

    defp check_type(%Cast{value: value} = ctx, :object) when is_map(value) do
      Enum.reduce_while(value, :ok, fn {key, value}, :ok ->
        if is_binary(key) and is_binary(value) do
          {:cont, :ok}
        else
          field_ctx = %{ctx | value: value, path: [key | ctx.path]}
          {:halt, Cast.error(field_ctx, {:invalid_type, :string})}
        end
      end)
    end

    defp check_type(%Cast{} = ctx, type), do: Cast.error(ctx, {:invalid_type, type})
  end
end
