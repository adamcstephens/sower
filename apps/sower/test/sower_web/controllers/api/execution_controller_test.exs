defmodule SowerWeb.Api.ExecutionControllerTest do
  use SowerWeb.ConnCase, async: true
  alias Sower.Accounts.AccessToken
  alias Sower.Orchestration.Executions

  setup do
    user = Sower.AccountsFixtures.user_fixture()
    Sower.Repo.put_org_id(user.org_id)

    %{
      user: user,
      request: %{system: "x86_64-linux", path: "/bin/true", stdin: %{}},
      conn: build_conn() |> put_req_header("content-type", "application/json")
    }
  end

  defp authenticate(conn, user, roles) do
    {:ok, token} =
      AccessToken.create(%{
        "description" => "execution API",
        "user_id" => user.id,
        "org_id" => user.org_id,
        "permissions" => Enum.map(roles, &%{"role" => &1})
      })

    put_req_header(conn, "authorization", "Bearer " <> token.token)
  end

  test "accepts durable queued submission without a garden selector and records actor", context do
    conn = authenticate(context.conn, context.user, ["execution:create"])
    response = conn |> post(~p"/api/v1/executions", context.request) |> json_response(202)
    assert response["state"] == "queued"
    assert response["queue_reason"] == "no_eligible_capacity"
    assert response["garden_sid"] == nil
    execution = Executions.get(response["sid"])
    assert execution.request["memory"] == 4_294_967_296
    assert execution.actor_sid == response["actor_sid"]
    assert execution.org_id == context.user.org_id
  end

  test "explicit JSON null stdin is distinct from a missing payload", context do
    conn = authenticate(context.conn, context.user, ["execution:create"])

    response =
      conn |> post(~p"/api/v1/executions", %{context.request | stdin: nil}) |> json_response(202)

    assert Map.has_key?(response["request"], "stdin")
    assert response["request"]["stdin"] == nil
    missing = Map.delete(context.request, :stdin)

    assert conn
           |> recycle()
           |> put_req_header("content-type", "application/json")
           |> post(~p"/api/v1/executions", missing)
           |> json_response(422)
  end

  test "deployment authority is not command, log or cancellation authority", context do
    conn = authenticate(context.conn, context.user, ["deployment:write", "deployment:read"])
    assert conn |> post(~p"/api/v1/executions", context.request) |> json_response(403)
    assert conn |> recycle() |> get(~p"/api/v1/executions") |> json_response(403)

    assert conn
           |> recycle()
           |> post(~p"/api/v1/executions/exec_other/cancel")
           |> json_response(403)
  end

  test "rejects builder selectors, custom image fields and malformed literal commands", context do
    conn = authenticate(context.conn, context.user, ["execution:create"])

    for invalid <- [
          Map.put(context.request, :garden, "somewhere"),
          Map.put(context.request, :image, "/nix/store/custom"),
          %{context.request | path: "relative"},
          Map.put(context.request, :args, ["bad\0arg"]),
          Map.put(context.request, :env, %{"A=B" => "bad"}),
          Map.put(context.request, :stdin, String.duplicate("x", 65536))
        ] do
      assert conn
             |> recycle()
             |> put_req_header("content-type", "application/json")
             |> post(~p"/api/v1/executions", invalid)
             |> json_response(422)
    end
  end

  test "cross-org read/history/cancel/list cannot reveal or change an execution", context do
    owner = authenticate(context.conn, context.user, ["execution:create"])
    response = owner |> post(~p"/api/v1/executions", context.request) |> json_response(202)
    sid = response["sid"]
    other = Sower.AccountsFixtures.user_fixture()
    Sower.Repo.put_org_id(other.org_id)
    stranger = authenticate(context.conn, other, ["execution:read", "execution:cancel"])
    assert stranger |> get(~p"/api/v1/executions/#{sid}") |> json_response(404)
    assert stranger |> recycle() |> get(~p"/api/v1/executions/#{sid}/logs") |> json_response(404)

    assert stranger
           |> recycle()
           |> post(~p"/api/v1/executions/#{sid}/cancel")
           |> json_response(404)

    assert stranger |> recycle() |> get(~p"/api/v1/executions") |> json_response(200) == []
    Sower.Repo.put_org_id(context.user.org_id)
    assert Executions.get(sid).state == "queued"
  end
end
