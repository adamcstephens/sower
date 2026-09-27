defmodule Sower.CircusIngestion do
  @moduledoc """
  Imports only manifest products of successful builds belonging to a configured
  Circus project. Callback data is never used as publication provenance.
  """

  alias Sower.Nix.Cache
  alias Sower.Orchestration.Seed
  alias Sower.Repo

  @schema_path Path.expand("../../../../nix/seed-manifest.schema.json", __DIR__)
  @external_resource @schema_path
  @manifest_schema @schema_path
                   |> File.read!()
                   |> Jason.decode!()
                   |> ExJsonSchema.Schema.resolve()
  @manifest_product ~r|\A/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-seed-manifest-[^/]+\.json\z|
  @branch_scope ~r/\Abranch:([^\s:]+)\z/

  def ingest(project_id, build_id, request \\ CircusClient.new(), opts \\ []) do
    with {:ok, org_id} <- trusted_org(project_id),
         {:ok, build} <- CircusClient.get_build(request, build_id),
         true <-
           build.id == build_id and build.status == "succeeded" and
             is_binary(build.evaluation_id),
         {:ok, evaluation} <- CircusClient.get_evaluation(request, build.evaluation_id),
         true <-
           evaluation.id == build.evaluation_id and evaluation.status == "completed" and
             is_binary(evaluation.jobset_id),
         {:ok, jobset} <- CircusClient.get_jobset(request, project_id, evaluation.jobset_id),
         true <- jobset.id == evaluation.jobset_id and jobset.project_id == project_id,
         {:ok, branch, order} <- provenance(evaluation),
         {:ok, products} <- CircusClient.list_products(request, build.id),
         {:ok, product} <- manifest_product(build, products),
         {:ok, bytes} <- CircusClient.download_product(request, build.id, product.id),
         {:ok, descriptor} <- parse_manifest(bytes, product.path),
         :ok <- cache_accessible(org_id, descriptor.artifact, opts) do
      source = %{
        instance: Keyword.fetch!(Application.fetch_env!(:sower, CircusClient), :instance),
        project: project_id,
        job: build.job_name,
        branch: branch,
        evaluation: evaluation.id,
        build: build.id,
        revision: evaluation.commit_hash,
        order: order
      }

      previous_org = Repo.get_org_id()
      Repo.put_org_id(org_id)

      try do
        Seed.publish(source, descriptor)
      after
        Repo.put_org_id(previous_org)
      end
    else
      false ->
        :skip

      {:error, reason}
      when reason in [
             :untrusted_project,
             :invalid_provenance,
             :invalid_manifest,
             :no_manifest_product,
             :ambiguous_manifest_product
           ] ->
        :skip

      {:error, reason} ->
        {:error, reason}
    end
  end

  def trusted_org(project_id) when is_binary(project_id) do
    projects = Application.fetch_env!(:sower, CircusClient) |> Keyword.fetch!(:projects)

    case Map.fetch(projects, project_id) do
      {:ok, org_id} when is_binary(org_id) -> {:ok, org_id}
      _ -> {:error, :untrusted_project}
    end
  end

  def trusted_org(_), do: {:error, :untrusted_project}

  def provenance(%CircusClient.Evaluation{} = evaluation) do
    with true <- evaluation.trigger_kind == "source_change",
         true <-
           is_nil(evaluation.pr_number) and is_nil(evaluation.pr_head_branch) and
             is_nil(evaluation.pr_base_branch),
         [_, branch] <- Regex.run(@branch_scope, evaluation.source_scope || ""),
         true <- branch != "HEAD" and not String.starts_with?(branch, "refs/pull/"),
         revision when is_binary(revision) and revision != "" <- evaluation.commit_hash,
         {:ok, time, _} <- DateTime.from_iso8601(evaluation.evaluation_time || "") do
      {:ok, branch, DateTime.to_unix(time, :microsecond)}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  def parse_manifest(bytes, product_path) when is_binary(bytes) and is_binary(product_path) do
    with {:ok, manifest} <- Jason.decode(bytes),
         :ok <- ExJsonSchema.Validator.validate(@manifest_schema, manifest),
         true <- String.ends_with?(product_path, "-seed-manifest-#{manifest["name"]}.json"),
         %{"name" => name, "seed_type" => seed_type, "artifact" => artifact, "tags" => tags} <-
           manifest do
      {:ok,
       %{
         name: name,
         seed_type: seed_type,
         artifact: artifact,
         tags:
           tags
           |> Map.drop(["git_branch", "git_rev"])
           |> Enum.map(fn {key, value} -> %{key: key, value: value} end)
       }}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  def parse_manifest(_, _), do: {:error, :invalid_manifest}

  defp manifest_product(build, products) do
    matching =
      Enum.filter(products, fn product ->
        product.build_id == build.id and product.is_directory == false and
          is_binary(product.path) and Regex.match?(@manifest_product, product.path) and
          output_path?(build, product.path)
      end)

    case matching do
      [product] -> {:ok, product}
      [] -> {:error, :no_manifest_product}
      _ -> {:error, :ambiguous_manifest_product}
    end
  end

  defp output_path?(build, path) do
    path == build.build_output_path or
      case build.outputs do
        outputs when is_map(outputs) -> path in Map.values(outputs)
        outputs when is_list(outputs) -> path in outputs
        _ -> false
      end
  end

  defp cache_accessible(org_id, artifact, opts) do
    previous_org = Repo.get_org_id()
    Repo.put_org_id(org_id)

    caches =
      try do
        Repo.all(Cache)
      after
        Repo.put_org_id(previous_org)
      end

    request = Keyword.get(opts, :cache_request, Req.new(retry: false, redirect: false))
    <<"/nix/store/", hash::binary-size(32), _::binary>> = artifact

    if Enum.any?(caches, fn cache ->
         cache_serves?(request, cache, artifact, hash)
       end) do
      :ok
    else
      {:error, :artifact_unavailable}
    end
  end

  defp cache_serves?(request, %Cache{} = cache, artifact, hash) do
    base_url = String.trim_trailing(cache.url, "/")
    key_name = cache.public_key |> String.split(":", parts: 2) |> hd()

    case Req.get(request, url: "#{base_url}/#{hash}.narinfo") do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        lines = String.split(body, "\n")

        with true <- "StorePath: #{artifact}" in lines,
             true <- Enum.any?(lines, &String.starts_with?(&1, "Sig: #{key_name}:")),
             ["URL: " <> nar_path] <- Enum.filter(lines, &String.starts_with?(&1, "URL: ")),
             true <- safe_nar_path?(nar_path),
             {:ok, %Req.Response{status: 200}} <-
               Req.request(request, method: :head, url: "#{base_url}/#{nar_path}") do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp safe_nar_path?(relative_url) do
    uri = URI.parse(relative_url)
    path = uri.path || ""

    is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.userinfo) and
      is_nil(uri.fragment) and path != "" and not String.starts_with?(path, "/") and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) and
      Regex.match?(~r/\A[a-zA-Z0-9_+\/.-]+\z/, path) and
      (is_nil(uri.query) or Regex.match?(~r/\A[a-zA-Z0-9_+%=.&-]*\z/, uri.query))
  end
end
