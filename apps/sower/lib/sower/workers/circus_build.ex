defmodule Sower.Workers.CircusBuild do
  use Oban.Worker,
    queue: :default,
    max_attempts: 15,
    unique: [
      period: 600,
      fields: [:worker, :args],
      keys: [:project_id, :build_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id, "build_id" => build_id}}) do
    case Sower.CircusIngestion.ingest(project_id, build_id) do
      {:ok, _seed} -> :ok
      :skip -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
