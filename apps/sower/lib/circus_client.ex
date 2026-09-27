defmodule CircusClient do
  defmodule Project do
    use TypedStruct

    typedstruct do
      field :id, String.t(), enforce: true
      field :name, String.t(), enforce: true
      field :repository_url, String.t(), enforce: true
    end
  end

  defmodule ProjectPage do
    use TypedStruct

    typedstruct do
      field :items, [Project.t()], enforce: true
      field :total, non_neg_integer(), enforce: true
      field :limit, pos_integer(), enforce: true
      field :offset, non_neg_integer(), enforce: true
    end
  end

  defmodule Evaluation do
    use TypedStruct

    typedstruct do
      field :id, String.t(), enforce: true
      field :jobset_id, String.t(), enforce: true
      field :commit_hash, String.t(), enforce: true
      field :evaluation_time, String.t(), enforce: true
      field :status, String.t(), enforce: true
      field :trigger_kind, String.t(), enforce: true
      field :source_scope, String.t()
      field :pr_number, integer()
      field :pr_head_branch, String.t()
      field :pr_base_branch, String.t()
      field :source_base_commit, String.t()
    end
  end

  defmodule EvaluationPage do
    use TypedStruct

    typedstruct do
      field :items, [Evaluation.t()], enforce: true
      field :total, non_neg_integer(), enforce: true
      field :limit, pos_integer(), enforce: true
      field :offset, non_neg_integer(), enforce: true
    end
  end

  defmodule Build do
    use TypedStruct

    typedstruct do
      field :id, String.t(), enforce: true
      field :evaluation_id, String.t(), enforce: true
      field :job_name, String.t(), enforce: true
      field :status, String.t(), enforce: true
      field :drv_path, String.t()
      field :build_output_path, String.t()
      field :outputs, map()
      field :is_aggregate, boolean()
      field :created_at, String.t()
      field :completed_at, String.t()
      field :signed, boolean()
      field :system, String.t()
    end
  end

  defmodule BuildPage do
    use TypedStruct

    typedstruct do
      field :items, [Build.t()], enforce: true
      field :total, non_neg_integer(), enforce: true
      field :limit, pos_integer(), enforce: true
      field :offset, non_neg_integer(), enforce: true
    end
  end

  defmodule Product do
    use TypedStruct

    typedstruct do
      field :id, String.t(), enforce: true
      field :build_id, String.t(), enforce: true
      field :name, String.t(), enforce: true
      field :path, String.t(), enforce: true
      field :is_directory, boolean(), enforce: true
      field :sha256_hash, String.t()
      field :file_size, non_neg_integer()
      field :content_type, String.t()
    end
  end

  defmodule Jobset do
    use TypedStruct

    typedstruct do
      field :id, String.t(), enforce: true
      field :project_id, String.t(), enforce: true
      field :name, String.t(), enforce: true
      field :trigger_mode, String.t()
    end
  end

  defmodule JobsetPage do
    use TypedStruct

    typedstruct do
      field :items, [Jobset.t()], enforce: true
      field :total, non_neg_integer(), enforce: true
      field :limit, pos_integer(), enforce: true
      field :offset, non_neg_integer(), enforce: true
    end
  end

  def new do
    config = Application.fetch_env!(:sower, __MODULE__)

    Req.new(
      base_url: String.trim_trailing(Keyword.fetch!(config, :url), "/") <> "/api/v1",
      auth: {:bearer, Keyword.fetch!(config, :api_key)},
      retry: false
    )
  end

  def list_projects(request \\ new()) do
    get_json(request, "/projects", [], fn body ->
      parse_page(body, ProjectPage, &parse_project/1)
    end)
  end

  def list_evaluations(request \\ new(), opts \\ []) do
    get_json(
      request,
      "/evaluations",
      Keyword.take(opts, [:jobset_id, :status, :limit, :offset]),
      fn body -> parse_page(body, EvaluationPage, &parse_evaluation/1) end
    )
  end

  def get_evaluation(request, id) do
    get_json(request, "/evaluations/#{segment(id)}", [], &parse_evaluation/1)
  end

  def list_builds(request \\ new(), opts \\ []) do
    get_json(
      request,
      "/builds",
      Keyword.take(opts, [:evaluation_id, :status, :system, :job_name, :limit, :offset]),
      fn body -> parse_page(body, BuildPage, &parse_build/1) end
    )
  end

  def get_build(request, id) do
    get_json(request, "/builds/#{segment(id)}", [], &parse_build/1)
  end

  # Circus returns a plain array here, unlike its paginated build/evaluation lists.
  def list_products(request, build_id, _opts \\ []) do
    get_json(request, "/builds/#{segment(build_id)}/products", [], fn body ->
      parse_items(body, &parse_product/1)
    end)
  end

  def download_product(request, build_id, product_id) do
    path = "/builds/#{segment(build_id)}/products/#{segment(product_id)}/download"
    request(request, path, [], decode_body: false)
  end

  def list_jobsets(request, project_id, opts \\ []) do
    get_json(
      request,
      "/projects/#{segment(project_id)}/jobsets",
      Keyword.take(opts, [:limit, :offset]),
      fn body -> parse_page(body, JobsetPage, &parse_jobset/1) end
    )
  end

  def get_jobset(request, project_id, id) do
    get_json(
      request,
      "/projects/#{segment(project_id)}/jobsets/#{segment(id)}",
      [],
      &parse_jobset/1
    )
  end

  defp get_json(request, path, params, parser) do
    with {:ok, body} <- request(request, path, params),
         {:ok, parsed} <- parser.(body) do
      {:ok, parsed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(request, path, params, options \\ []) do
    case Req.get(request, [url: path, params: params, retry: false, redirect: false] ++ options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp parse_project(%{"id" => id, "name" => name, "repository_url" => repository_url})
       when is_binary(id) and is_binary(name) and is_binary(repository_url) do
    {:ok, %Project{id: id, name: name, repository_url: repository_url}}
  end

  defp parse_project(body), do: {:error, {:invalid_response, body}}

  defp parse_page(
         %{"items" => items, "total" => total, "limit" => limit, "offset" => offset} = body,
         page,
         parser
       )
       when is_list(items) and is_integer(total) and total >= 0 and is_integer(limit) and
              limit > 0 and
              is_integer(offset) and offset >= 0 do
    case parse_items(items, parser) do
      {:ok, parsed} ->
        {:ok, struct!(page, items: parsed, total: total, limit: limit, offset: offset)}

      {:error, _} ->
        {:error, {:invalid_response, body}}
    end
  end

  defp parse_page(body, _page, _parser), do: {:error, {:invalid_response, body}}

  defp parse_items(items, parser) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, parsed} ->
      case parser.(item) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_items(body, _parser), do: {:error, {:invalid_response, body}}

  defp parse_evaluation(
         %{
           "id" => id,
           "jobset_id" => jobset_id,
           "commit_hash" => commit_hash,
           "evaluation_time" => evaluation_time,
           "status" => status,
           "trigger_kind" => trigger_kind
         } = body
       )
       when is_binary(id) and is_binary(jobset_id) and is_binary(commit_hash) and
              is_binary(evaluation_time) and is_binary(status) and is_binary(trigger_kind) do
    {:ok,
     %Evaluation{
       id: id,
       jobset_id: jobset_id,
       commit_hash: commit_hash,
       evaluation_time: evaluation_time,
       status: status,
       trigger_kind: trigger_kind,
       source_scope: Map.get(body, "source_scope"),
       pr_number: Map.get(body, "pr_number"),
       pr_head_branch: Map.get(body, "pr_head_branch"),
       pr_base_branch: Map.get(body, "pr_base_branch"),
       source_base_commit: Map.get(body, "source_base_commit")
     }}
  end

  defp parse_evaluation(body), do: {:error, {:invalid_response, body}}

  defp parse_build(
         %{
           "id" => id,
           "evaluation_id" => evaluation_id,
           "job_name" => job_name,
           "status" => status
         } = body
       )
       when is_binary(id) and is_binary(evaluation_id) and is_binary(job_name) and
              is_binary(status) do
    {:ok,
     %Build{
       id: id,
       evaluation_id: evaluation_id,
       job_name: job_name,
       status: status,
       drv_path: Map.get(body, "drv_path"),
       build_output_path: Map.get(body, "build_output_path"),
       outputs: Map.get(body, "outputs"),
       is_aggregate: Map.get(body, "is_aggregate"),
       created_at: Map.get(body, "created_at"),
       completed_at: Map.get(body, "completed_at"),
       signed: Map.get(body, "signed"),
       system: Map.get(body, "system")
     }}
  end

  defp parse_build(body), do: {:error, {:invalid_response, body}}

  defp parse_product(
         %{
           "id" => id,
           "build_id" => build_id,
           "name" => name,
           "path" => path,
           "is_directory" => is_directory
         } = body
       )
       when is_binary(id) and is_binary(build_id) and is_binary(name) and is_binary(path) and
              is_boolean(is_directory) do
    {:ok,
     %Product{
       id: id,
       build_id: build_id,
       name: name,
       path: path,
       is_directory: is_directory,
       sha256_hash: Map.get(body, "sha256_hash"),
       file_size: Map.get(body, "file_size"),
       content_type: Map.get(body, "content_type")
     }}
  end

  defp parse_product(body), do: {:error, {:invalid_response, body}}

  defp parse_jobset(%{"id" => id, "project_id" => project_id, "name" => name} = body)
       when is_binary(id) and is_binary(project_id) and is_binary(name) do
    {:ok,
     %Jobset{
       id: id,
       project_id: project_id,
       name: name,
       trigger_mode: Map.get(body, "trigger_mode")
     }}
  end

  defp parse_jobset(body), do: {:error, {:invalid_response, body}}
end
