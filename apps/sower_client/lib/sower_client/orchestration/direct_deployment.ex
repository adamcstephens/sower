defmodule SowerClient.Orchestration.DirectDeployment do
  @moduledoc """
  Request to deploy a seed straight at a garden over the HTTP API.
  """
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "DirectDeployment",
    type: :object,
    properties: %{
      garden: %Schema{
        type: :string,
        description: "Garden sid (grdn_…) or garden name",
        example: "grdn_2f8b1c"
      },
      seed: %Schema{
        type: :string,
        description: "Seed sid to deploy",
        example: "seed_9a3d21"
      },
      action: %Schema{
        type: :string,
        enum: SowerClient.Orchestration.Subscription.Policy.actions(),
        description: "Requested action. Required when overriding policy.",
        nullable: true
      },
      force: %Schema{
        type: :boolean,
        description: "Deploy even when an identical closure was already deployed",
        default: false
      },
      override: %Schema{
        type: :boolean,
        description: "Break glass: bypass the garden's policy. Requires action and reason.",
        default: false
      },
      reason: %Schema{
        type: :string,
        description: "Why policy is being bypassed. Recorded in the audit trail.",
        nullable: true
      }
    },
    required: [:garden, :seed]
  })

  def create(%__MODULE__{} = request) do
    create(SowerClient.ApiClient.new(), request)
  end

  def create(%Req.Request{} = req, %__MODULE__{} = request) do
    case Req.post(req, url: "/deployments", json: request) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        SowerClient.Orchestration.DeploymentInfo.cast(body)

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, _} = err ->
        err
    end
  end
end
