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
end
