defmodule SowerWeb.CircusWebhookControllerTest do
  use SowerWeb.ConnCase

  setup do
    previous = Application.get_env(:sower, CircusClient)

    Application.put_env(:sower, CircusClient,
      url: "http://127.0.0.1:3000",
      api_key: "test",
      instance: "local",
      webhook_secret: "secret",
      projects: %{"approved-project" => "00000000-0000-0000-0000-000000000001"}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sower, CircusClient, previous),
        else: Application.delete_env(:sower, CircusClient)
    end)

    :ok
  end

  test "signed callback acknowledges durable work", %{conn: conn} do
    body = ~s({"build_id":"some-build","project_name":"untrusted"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-circus-signature", sign(body))
      |> post("/circus/webhook", body)

    assert response(conn, 202)

    assert [%Oban.Job{worker: "Sower.Workers.CircusReconcile"}] =
             Sower.Repo.all(Oban.Job)
  end

  test "rejects a signature computed over another body", %{conn: conn} do
    body = ~s({"build_id":"some-build"})
    signature = sign(~s({"build_id":"other-build"}))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-circus-signature", signature)
      |> post("/circus/webhook", body)

    assert response(conn, 401)
  end

  test "rejects unsigned callbacks", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/circus/webhook", ~s({"build_id":"some-build"}))

    assert response(conn, 401)
  end

  defp sign(body) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, "secret", body), case: :lower)
  end
end
