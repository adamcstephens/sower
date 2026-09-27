defmodule Sower.Workers.CircusReconcile do
  use Oban.Worker,
    queue: :default,
    max_attempts: 8,
    unique: [
      period: 60,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query, only: [from: 2]

  alias Sower.Orchestration.SeedPublication
  alias Sower.Repo

  alias Sower.Workers.CircusBuild

  @page_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{}}) do
    reconcile()
  end

  def reconcile(request \\ CircusClient.new()) do
    projects = Application.fetch_env!(:sower, CircusClient) |> Keyword.fetch!(:projects)

    Enum.reduce_while(Map.keys(projects), :ok, fn project_id, :ok ->
      case reconcile_project(request, project_id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp reconcile_project(request, project_id) do
    with {:ok, org_id} <- Sower.CircusIngestion.trusted_org(project_id) do
      previous_org = Repo.get_org_id()
      Repo.put_org_id(org_id)

      try do
        each_page(
          fn offset ->
            CircusClient.list_jobsets(request, project_id, limit: @page_size, offset: offset)
          end,
          fn jobset ->
            if jobset.project_id == project_id do
              reconcile_jobset(request, project_id, jobset.id)
            else
              {:error, :jobset_project_mismatch}
            end
          end
        )
      after
        Repo.put_org_id(previous_org)
      end
    else
      {:error, _} = error -> error
    end
  end

  defp reconcile_jobset(request, project_id, jobset_id) do
    each_page(
      fn offset ->
        CircusClient.list_evaluations(request,
          jobset_id: jobset_id,
          limit: @page_size,
          offset: offset
        )
      end,
      fn evaluation ->
        if evaluation.jobset_id == jobset_id do
          reconcile_evaluation(request, project_id, evaluation.id)
        else
          {:error, :evaluation_jobset_mismatch}
        end
      end
    )
  end

  defp reconcile_evaluation(request, project_id, evaluation_id) do
    each_page(
      fn offset ->
        CircusClient.list_builds(request,
          evaluation_id: evaluation_id,
          limit: @page_size,
          offset: offset
        )
      end,
      fn build ->
        cond do
          build.evaluation_id != evaluation_id ->
            {:error, :build_evaluation_mismatch}

          build.status == "succeeded" and published?(project_id, evaluation_id, build) ->
            :ok

          build.status == "succeeded" ->
            %{"project_id" => project_id, "build_id" => build.id}
            |> CircusBuild.new()
            |> Oban.insert()
            |> case do
              {:ok, _job} -> :ok
              {:error, reason} -> {:error, reason}
            end

          true ->
            :ok
        end
      end
    )
  end

  defp published?(project_id, evaluation_id, build) do
    instance = Application.fetch_env!(:sower, CircusClient) |> Keyword.fetch!(:instance)

    Repo.exists?(
      from(p in SeedPublication,
        where:
          p.instance == ^instance and p.project == ^project_id and
            p.job == ^build.job_name and p.evaluation == ^evaluation_id and
            p.build == ^build.id
      )
    )
  end

  # Page in-place, without accumulating an unbounded history in the scheduler.
  # If any remote read or enqueue fails, Oban retries the entire scan; completed
  # publications are safe to revisit through Seed.publish/2.
  defp each_page(fetch, consume), do: each_page(fetch, consume, 0)

  defp each_page(fetch, consume, offset) do
    with {:ok, page} <- fetch.(offset),
         true <- page.offset == offset and is_integer(page.total),
         :ok <- consume_items(page.items, consume) do
      next = offset + length(page.items)

      cond do
        next >= page.total -> :ok
        next == offset -> {:error, :incomplete_page}
        true -> each_page(fetch, consume, next)
      end
    else
      false -> {:error, :invalid_page}
      {:error, _} = error -> error
    end
  end

  defp consume_items(items, consume) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case consume.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
