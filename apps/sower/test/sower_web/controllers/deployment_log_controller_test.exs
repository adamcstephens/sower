defmodule SowerWeb.DeploymentLogControllerTest do
  use SowerWeb.ConnCase, async: true

  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias SowerWeb.DeploymentLogController
  alias SowerClient.Orchestration.SeedDeployment

  setup [:register_and_log_in_user]

  setup %{user: user} do
    Sower.Repo.put_org_id(user.org_id)

    agent = agent_fixture()
    seed = seed_fixture()
    other_seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        agent_id: agent.id,
        seeds: [seed],
        subscriptions: []
      })

    %{deployment: deployment, seed: seed, other_seed: other_seed}
  end

  test "show/3 redirects to a presigned download url when log exists", %{
    conn: conn,
    deployment: deployment,
    seed: seed
  } do
    expected_path = SeedDeployment.log_path(deployment.sid, seed.sid)

    conn =
      DeploymentLogController.show(
        conn,
        %{"sid" => deployment.sid, "seed_sid" => seed.sid},
        presign_head_fun: fn path, opts ->
          assert path == expected_path
          assert opts[:expires_in] == 5 * 60
          {:ok, "https://example.com/head"}
        end,
        req_head_fun: fn opts ->
          assert opts[:url] == "https://example.com/head"
          assert opts[:retry] == false
          {:ok, %Req.Response{status: 200}}
        end,
        presign_download_fun: fn path, opts ->
          assert path == expected_path
          assert opts[:expires_in] == 5 * 60
          {:ok, "https://example.com/download"}
        end
      )

    assert redirected_to(conn) == "https://example.com/download"
  end

  test "show/3 returns no log when storage object is missing", %{
    conn: conn,
    deployment: deployment,
    seed: seed
  } do
    conn =
      DeploymentLogController.show(
        conn,
        %{"sid" => deployment.sid, "seed_sid" => seed.sid},
        presign_head_fun: fn _, _ -> {:ok, "https://example.com/head"} end,
        req_head_fun: fn _ -> {:ok, %Req.Response{status: 404}} end
      )

    assert response(conn, 404) == "no log"
  end

  test "show/3 returns not found when seed is not part of deployment", %{
    conn: conn,
    deployment: deployment,
    other_seed: other_seed
  } do
    conn =
      DeploymentLogController.show(
        conn,
        %{"sid" => deployment.sid, "seed_sid" => other_seed.sid},
        []
      )

    assert response(conn, 404) == "Not found"
  end
end
