defmodule SowerClient.Orchestration.DeploymentInfo do
  @moduledoc """
  Deployment state as reported by the HTTP API, for polling a direct deploy.
  """
  use SowerClient.Schema

  defmodule SeedInfo do
    use SowerClient.Schema

    OpenApiSpex.schema(%{
      title: "DeploymentSeedInfo",
      type: :object,
      properties: %{
        seed_sid: %Schema{type: :string},
        name: %Schema{type: :string},
        seed_type: %Schema{type: :string},
        state: %Schema{type: :string, nullable: true},
        result: %Schema{type: :string, nullable: true},
        log: %Schema{type: :string, nullable: true}
      },
      required: [:seed_sid, :name, :seed_type]
    })
  end

  OpenApiSpex.schema(%{
    title: "DeploymentInfo",
    type: :object,
    properties: %{
      sid: %Schema{type: :string},
      garden_sid: %Schema{type: :string},
      state: %Schema{type: :string},
      result: %Schema{type: :string, nullable: true},
      deployed_at: %Schema{type: :string, format: :"date-time", nullable: true},
      skipped: %Schema{
        type: :boolean,
        description: "The request matched an existing deployment and no new one was created",
        default: false
      },
      seeds: %Schema{type: :array, items: SeedInfo, default: []}
    },
    required: [:sid, :garden_sid, :state]
  })

  def get(sid) do
    get(SowerClient.ApiClient.new(), sid)
  end

  def get(%Req.Request{} = req, sid) do
    case Req.get(req, url: "/deployments/:sid", path_params: [sid: sid]) do
      {:ok, %{status: 200, body: body}} ->
        cast(body)

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, _} = err ->
        err
    end
  end
end
