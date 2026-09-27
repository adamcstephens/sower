defmodule CircusClientTest do
  use ExUnit.Case

  test "lists project data through the authenticated Circus API" do
    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        auth: {:bearer, "test-key"},
        plug: fn conn ->
          assert conn.method == "GET"
          assert conn.request_path == "/api/v1/projects"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

          Req.Test.json(conn, %{
            items: [
              %{id: "project-123", name: "Sower", repository_url: "https://forge.example/sower"}
            ],
            total: 1,
            limit: 50,
            offset: 0
          })
        end
      )

    assert {:ok,
            %CircusClient.ProjectPage{
              items: [%CircusClient.Project{} = project],
              total: 1,
              limit: 50,
              offset: 0
            }} =
             CircusClient.list_projects(request)

    assert project.id == "project-123"
    assert project.name == "Sower"
    assert project.repository_url == "https://forge.example/sower"
  end

  test "configured Circus URL ending in a slash reaches the projects endpoint" do
    previous_config = Application.get_env(:sower, CircusClient)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:sower, CircusClient, previous_config)
      else
        Application.delete_env(:sower, CircusClient)
      end
    end)

    Application.put_env(:sower, CircusClient,
      url: "http://circus.test/",
      api_key: "test-key"
    )

    request =
      CircusClient.new()
      |> Req.merge(
        plug: fn conn ->
          assert conn.request_path == "/api/v1/projects"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
          Req.Test.json(conn, %{items: [], total: 0, limit: 50, offset: 0})
        end
      )

    assert {:ok, %CircusClient.ProjectPage{items: [], total: 0}} =
             CircusClient.list_projects(request)
  end

  test "rejects invalid Circus credentials explicitly" do
    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        plug: fn conn -> Plug.Conn.resp(conn, 401, "") end
      )

    assert {:error, :unauthorized} = CircusClient.list_projects(request)
  end

  test "lists filtered evaluations and builds with their actual upstream pagination and provenance" do
    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        auth: {:bearer, "test-key"},
        plug: fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
          params = URI.decode_query(conn.query_string)
          assert params["limit"] == "1"
          assert params["offset"] == "2"

          case conn.request_path do
            "/api/v1/evaluations" ->
              assert params["jobset_id"] == "jobset-1"
              assert params["status"] == "completed"

              Req.Test.json(conn, %{
                items: [
                  %{
                    id: "eval-1",
                    jobset_id: "jobset-1",
                    commit_hash: "abc123",
                    evaluation_time: "2026-09-27T10:00:00Z",
                    status: "completed",
                    trigger_kind: "source_change",
                    source_scope: "branch:main"
                  }
                ],
                total: 4,
                limit: 1,
                offset: 2
              })

            "/api/v1/builds" ->
              assert params["evaluation_id"] == "eval-1"
              assert params["status"] == "succeeded"

              Req.Test.json(conn, %{
                items: [
                  %{
                    id: "build-1",
                    evaluation_id: "eval-1",
                    job_name: "manifest/nixos/web",
                    status: "succeeded",
                    build_output_path: "/nix/store/abc-seed-manifest-web.json",
                    outputs: %{"out" => "/nix/store/abc-seed-manifest-web.json"},
                    is_aggregate: false,
                    created_at: "2026-09-27T10:01:00Z",
                    completed_at: "2026-09-27T10:02:00Z"
                  }
                ],
                total: 5,
                limit: 1,
                offset: 2
              })
          end
        end
      )

    assert {:ok, %CircusClient.EvaluationPage{total: 4, limit: 1, offset: 2, items: [evaluation]}} =
             CircusClient.list_evaluations(request,
               jobset_id: "jobset-1",
               status: "completed",
               limit: 1,
               offset: 2
             )

    assert %CircusClient.Evaluation{
             id: "eval-1",
             commit_hash: "abc123",
             source_scope: "branch:main",
             trigger_kind: "source_change",
             evaluation_time: "2026-09-27T10:00:00Z"
           } = evaluation

    assert {:ok, %CircusClient.BuildPage{total: 5, limit: 1, offset: 2, items: [build]}} =
             CircusClient.list_builds(request,
               evaluation_id: "eval-1",
               status: "succeeded",
               limit: 1,
               offset: 2
             )

    assert %CircusClient.Build{
             id: "build-1",
             evaluation_id: "eval-1",
             job_name: "manifest/nixos/web",
             status: "succeeded",
             outputs: %{"out" => "/nix/store/abc-seed-manifest-web.json"}
           } = build
  end

  test "resolves jobset ownership from the returned record rather than the requested path" do
    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        plug: fn conn ->
          case conn.request_path do
            "/api/v1/projects/claimed/jobsets/jobset-1" ->
              Req.Test.json(conn, %{id: "jobset-1", project_id: "actual", name: "release"})

            "/api/v1/projects/actual/jobsets" ->
              assert URI.decode_query(conn.query_string) == %{"limit" => "1", "offset" => "1"}

              Req.Test.json(conn, %{
                items: [%{id: "jobset-1", project_id: "actual", name: "release"}],
                total: 2,
                limit: 1,
                offset: 1
              })
          end
        end
      )

    assert {:ok, %CircusClient.Jobset{project_id: "actual"}} =
             CircusClient.get_jobset(request, "claimed", "jobset-1")

    assert {:ok,
            %CircusClient.JobsetPage{items: [%CircusClient.Jobset{id: "jobset-1"}], total: 2}} =
             CircusClient.list_jobsets(request, "actual", limit: 1, offset: 1)
  end

  test "fetches authoritative records and downloads a file product as unmodified bytes" do
    bytes = <<0, 255, 123, 10, 125>>

    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        plug: fn conn ->
          case conn.request_path do
            "/api/v1/evaluations/eval-1" ->
              Req.Test.json(conn, %{
                id: "eval-1",
                jobset_id: "jobset-1",
                commit_hash: "abc",
                evaluation_time: "2026-09-27T10:00:00Z",
                status: "completed",
                trigger_kind: "source_change",
                source_scope: "branch:main"
              })

            "/api/v1/builds/build-1" ->
              Req.Test.json(conn, %{
                id: "build-1",
                evaluation_id: "eval-1",
                job_name: "manifest/nixos/web",
                status: "succeeded",
                outputs: %{"out" => "/nix/store/abc-seed-manifest-web.json"},
                is_aggregate: false,
                created_at: "2026-09-27T10:01:00Z"
              })

            "/api/v1/builds/build-1/products" ->
              Req.Test.json(conn, [
                %{
                  id: "product-1",
                  build_id: "build-1",
                  name: "out",
                  path: "/nix/store/abc-seed-manifest-web.json",
                  is_directory: false,
                  sha256_hash: "abc",
                  file_size: 5,
                  content_type: nil
                }
              ])

            "/api/v1/builds/build-1/products/product-1/download" ->
              Plug.Conn.resp(conn, 200, bytes)
          end
        end
      )

    assert {:ok, %CircusClient.Evaluation{id: "eval-1"}} =
             CircusClient.get_evaluation(request, "eval-1")

    assert {:ok, %CircusClient.Build{id: "build-1"}} = CircusClient.get_build(request, "build-1")

    assert {:ok, [%CircusClient.Product{is_directory: false, path: path}]} =
             CircusClient.list_products(request, "build-1")

    assert path == "/nix/store/abc-seed-manifest-web.json"
    assert {:ok, ^bytes} = CircusClient.download_product(request, "build-1", "product-1")
  end

  test "returns explicit errors for unauthorized, unavailable, and malformed responses" do
    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        plug: fn conn ->
          case conn.request_path do
            "/api/v1/evaluations" -> Plug.Conn.resp(conn, 401, "")
            "/api/v1/builds" -> Plug.Conn.resp(conn, 503, "")
            "/api/v1/builds/build-1/products" -> Req.Test.json(conn, %{items: []})
            "/api/v1/builds/build-1/products/product-1/download" -> Plug.Conn.resp(conn, 404, "")
          end
        end
      )

    assert {:error, :unauthorized} = CircusClient.list_evaluations(request)
    assert {:error, {:http, 503}} = CircusClient.list_builds(request)
    assert {:error, {:invalid_response, _}} = CircusClient.list_products(request, "build-1")
    assert {:error, {:http, 404}} = CircusClient.download_product(request, "build-1", "product-1")
  end

  test "keeps JSON manifests as bytes and refuses redirects off the trusted Circus origin" do
    manifest = ~s({"version":1,"seed":{"name":"web"}})

    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        plug: fn conn ->
          case conn.request_path do
            "/api/v1/builds/build-1/products/product-1/download" ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.resp(200, manifest)

            "/api/v1/builds/build-2/products/product-2/download" ->
              conn
              |> Plug.Conn.put_resp_header("location", "https://untrusted.example/manifest.json")
              |> Plug.Conn.resp(302, "")
          end
        end
      )

    assert {:ok, ^manifest} = CircusClient.download_product(request, "build-1", "product-1")
    assert {:error, {:http, 302}} = CircusClient.download_product(request, "build-2", "product-2")
  end

  test "rejects malformed paginated records rather than treating them as completed builds" do
    request =
      Req.new(
        base_url: "http://circus.test/api/v1",
        plug: fn conn ->
          Req.Test.json(conn, %{
            items: [%{id: "build-1", status: "succeeded"}],
            total: 1,
            limit: 50,
            offset: 0
          })
        end
      )

    assert {:error, {:invalid_response, _}} = CircusClient.list_builds(request)
  end
end
