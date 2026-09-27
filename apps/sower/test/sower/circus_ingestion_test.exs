defmodule Sower.CircusIngestionTest do
  use Sower.DataCase

  import Sower.AccountsFixtures
  import Sower.NixFixtures

  alias Sower.CircusIngestion
  alias Sower.Orchestration.{Seed, SeedPublication}

  @store_hash "0123456789abcdfghijklmnpqrsvwxyz"
  @artifact "/nix/store/#{@store_hash}-nixos-system-example"
  @manifest_path "/nix/store/#{@store_hash}-seed-manifest-example.json"

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    cache_fixture(%{url: "http://cache.test/nix-cache", public_key: "trusted:base64"})
    previous = Application.get_env(:sower, CircusClient)

    Application.put_env(:sower, CircusClient,
      url: "http://circus.test",
      api_key: "test",
      instance: "http://circus.test",
      projects: %{"project-1" => org.org_id}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:sower, CircusClient, previous)
      else
        Application.delete_env(:sower, CircusClient)
      end
    end)

    %{org: org}
  end

  test "successful branch publication uses evaluation provenance, strips spoofed tags and replays safely" do
    request = circus_request()
    cache_request = cache_request()

    assert {:ok, %Seed{}} =
             CircusIngestion.ingest("project-1", "build-1", request, cache_request: cache_request)

    assert %SeedPublication{branch: "main", revision: "revision-1", source_order: order} =
             Repo.one!(SeedPublication)

    assert order == DateTime.to_unix(~U[2026-09-27 12:00:00Z], :microsecond)

    seed = Repo.one!(Seed) |> Repo.preload(:tags)
    assert seed.artifact == @artifact
    assert Enum.any?(seed.tags, &(&1.key == "env" and &1.value == "prod"))
    refute Enum.any?(seed.tags, &(&1.key in ["git_branch", "git_rev"]))

    assert %Seed{id: seed_id} =
             Seed.latest("example", "nixos", [
               %{key: "git_branch", value: "main"},
               %{key: "git_rev", value: "revision-1"}
             ])

    assert seed_id == seed.id
    refute Seed.latest("example", "nixos", [%{key: "git_branch", value: "fake"}])
    assert Repo.aggregate(Oban.Job, :count, :id) == 1

    assert {:ok, %Seed{id: id}} =
             CircusIngestion.ingest("project-1", "build-1", request, cache_request: cache_request)

    assert id == seed.id
    assert Repo.aggregate(SeedPublication, :count, :id) == 1
    assert Repo.aggregate(Oban.Job, :count, :id) == 1
  end

  test "failed and cached-failure builds, and untrusted project are excluded" do
    for status <- ["failed", "cached_failure"] do
      assert :skip =
               CircusIngestion.ingest("project-1", "build-1", circus_request(status: status),
                 cache_request: cache_request()
               )
    end

    assert :skip = CircusIngestion.ingest("other-project", "build-1", circus_request())

    assert :skip =
             CircusIngestion.ingest(
               "project-1",
               "build-1",
               circus_request(jobset_project: "other-project")
             )

    assert Repo.aggregate(SeedPublication, :count, :id) == 0
  end

  test "unrelated products cannot be mistaken for the selected manifest output" do
    unrelated_path = "/nix/store/#{String.reverse(@store_hash)}-seed-manifest-example.json"

    assert :skip =
             CircusIngestion.ingest(
               "project-1",
               "build-1",
               circus_request(product_path: unrelated_path)
             )

    assert Repo.aggregate(SeedPublication, :count, :id) == 0
  end

  test "manual, ambiguous and PR provenance cannot publish" do
    for {scope, trigger} <- [
          {nil, "manual"},
          {"branch:HEAD", "source_change"},
          {"branch:main", "manual"},
          {"refs/pull/1/head", "source_change"}
        ] do
      request = circus_request(scope: scope, trigger: trigger)
      assert :skip = CircusIngestion.ingest("project-1", "build-1", request)
    end

    assert :skip =
             CircusIngestion.ingest(
               "project-1",
               "build-1",
               circus_request(pr_number: 42, scope: "branch:main")
             )

    assert Repo.aggregate(SeedPublication, :count, :id) == 0
  end

  test "cache must advertise the exact artifact with a trusted signature" do
    request = circus_request()

    assert {:error, :artifact_unavailable} =
             CircusIngestion.ingest("project-1", "build-1", request,
               cache_request: cache_request(signed: false)
             )

    assert {:error, :artifact_unavailable} =
             CircusIngestion.ingest("project-1", "build-1", request,
               cache_request: cache_request(nar_status: 404)
             )

    assert Repo.aggregate(SeedPublication, :count, :id) == 0

    assert {:ok, %Seed{}} =
             CircusIngestion.ingest("project-1", "build-1", request,
               cache_request: cache_request()
             )

    assert Repo.aggregate(SeedPublication, :count, :id) == 1
  end

  test "schema rejects extra fields and mismatched manifest identity" do
    manifest = manifest()

    assert {:error, :invalid_manifest} =
             CircusIngestion.parse_manifest(
               Jason.encode!(Map.put(manifest, "org_id", "spoof")),
               @manifest_path
             )

    assert {:error, :invalid_manifest} =
             CircusIngestion.parse_manifest(
               Jason.encode!(manifest),
               "/nix/store/#{@store_hash}-seed-manifest-another.json"
             )
  end

  test "reconciliation pages through evaluations and builds without scheduling failures" do
    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        retry: false,
        plug: fn raw_conn ->
          conn = Plug.Conn.fetch_query_params(raw_conn)
          offset = String.to_integer(conn.query_params["offset"] || "0")

          {items, total} =
            case conn.request_path do
              "/api/v1/projects/project-1/jobsets" ->
                {[%{"id" => "jobset-1", "project_id" => "project-1", "name" => "main"}], 1}

              "/api/v1/evaluations" ->
                evaluation = %{
                  "id" => "eval-#{offset}",
                  "jobset_id" => "jobset-1",
                  "commit_hash" => "revision-#{offset}",
                  "evaluation_time" => "2026-09-27T12:00:00Z",
                  "status" => "completed",
                  "source_scope" => "branch:main",
                  "trigger_kind" => "source_change"
                }

                {[evaluation], 2}

              "/api/v1/builds" ->
                evaluation_id = conn.query_params["evaluation_id"]
                status = if evaluation_id == "eval-0", do: "succeeded", else: "cached_failure"

                build = %{
                  "id" => "build-#{evaluation_id}-#{offset}",
                  "evaluation_id" => evaluation_id,
                  "job_name" => "seed-manifest-example.json",
                  "status" => status,
                  "build_output_path" => @manifest_path,
                  "outputs" => %{"out" => @manifest_path},
                  "is_aggregate" => false
                }

                {[build], 2}
            end

          body = %{"items" => items, "total" => total, "limit" => 1, "offset" => offset}

          Plug.Conn.resp(conn, 200, Jason.encode!(body))
          |> Plug.Conn.put_resp_header("content-type", "application/json")
        end
      )

    assert :ok = Sower.Workers.CircusReconcile.reconcile(request)
    assert Repo.aggregate(Oban.Job, :count, :id) == 2

    assert :ok = Sower.Workers.CircusReconcile.reconcile(request)
    assert Repo.aggregate(Oban.Job, :count, :id) == 2
  end

  defp manifest do
    %{
      "version" => 1,
      "name" => "example",
      "seed_type" => "nixos",
      "artifact" => @artifact,
      "tags" => %{"env" => "prod", "git_branch" => "fake", "git_rev" => "fake-sha"}
    }
  end

  defp circus_request(opts \\ []) do
    status = Keyword.get(opts, :status, "succeeded")
    scope = Keyword.get(opts, :scope, "branch:main")
    trigger = Keyword.get(opts, :trigger, "source_change")
    jobset_project = Keyword.get(opts, :jobset_project, "project-1")
    pr_number = Keyword.get(opts, :pr_number)
    product_path = Keyword.get(opts, :product_path, @manifest_path)

    Req.new(
      base_url: "http://circus.test/api/v1",
      retry: false,
      plug: fn conn ->
        body =
          case conn.request_path do
            "/api/v1/builds/build-1" ->
              %{
                "id" => "build-1",
                "evaluation_id" => "eval-1",
                "job_name" => "seed-manifest-example.json",
                "status" => status,
                "build_output_path" => @manifest_path,
                "outputs" => %{"out" => @manifest_path},
                "is_aggregate" => false,
                "created_at" => "2026-09-27T12:01:00Z",
                "completed_at" => "2026-09-27T12:03:00Z"
              }

            "/api/v1/evaluations/eval-1" ->
              %{
                "id" => "eval-1",
                "jobset_id" => "jobset-1",
                "commit_hash" => "revision-1",
                "evaluation_time" => "2026-09-27T12:00:00Z",
                "status" => "completed",
                "source_scope" => scope,
                "trigger_kind" => trigger,
                "pr_number" => pr_number,
                "pr_head_branch" => nil,
                "pr_base_branch" => nil
              }

            "/api/v1/projects/project-1/jobsets/jobset-1" ->
              %{"id" => "jobset-1", "project_id" => jobset_project, "name" => "main"}

            "/api/v1/builds/build-1/products" ->
              [
                %{
                  "id" => "product-1",
                  "build_id" => "build-1",
                  "name" => "out",
                  "path" => product_path,
                  "sha256_hash" => "hash",
                  "file_size" => 123,
                  "content_type" => "application/json",
                  "is_directory" => false
                }
              ]

            "/api/v1/builds/build-1/products/product-1/download" ->
              manifest()
          end

        Plug.Conn.resp(conn, 200, Jason.encode!(body))
        |> Plug.Conn.put_resp_header("content-type", "application/json")
      end
    )
  end

  defp cache_request(opts \\ []) do
    signed = Keyword.get(opts, :signed, true)
    nar_status = Keyword.get(opts, :nar_status, 200)

    Req.new(
      retry: false,
      plug: fn conn ->
        case conn.request_path do
          "/nix-cache/#{@store_hash}.narinfo" ->
            signature = if signed, do: "Sig: trusted:base64\n", else: ""

            Plug.Conn.resp(
              conn,
              200,
              "StorePath: #{@artifact}\nURL: nar/artifact.nar.zst?hash=#{@store_hash}\n#{signature}"
            )

          "/nix-cache/nar/artifact.nar.zst" ->
            assert conn.method == "HEAD"
            assert conn.query_string == "hash=#{@store_hash}"
            Plug.Conn.resp(conn, nar_status, "")
        end
      end
    )
  end
end
