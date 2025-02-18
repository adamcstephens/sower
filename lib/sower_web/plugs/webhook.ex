defmodule SowerWeb.Plugs.Webhook do
  use SowerWeb, :verified_routes

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    verify_webhook(conn)
  end

  defp verify_webhook(conn) do
    with %{"repo_id" => repo_id} <- conn.path_params,
         repo <- Sower.Forge.get_global_repository!(repo_id),
         repo <- Sower.Repo.preload(repo, :forge),
         {:ok, verified_conn} <- check_webhook_signature(repo, conn) do
      verified_conn
    else
      _ ->
        conn |> send_unauthorized()
    end
  end

  defp check_webhook_signature(%Sower.Forge.Repository{} = repo, conn) do
    with [signature] <- get_req_header(conn, forge_header(repo.forge)),
         {:ok, raw_body, _conn} <- read_body(conn),
         true <- verify_payload(raw_body, repo.webhook_secret, signature),
         {:ok, body_params} <- Phoenix.json_library().decode(raw_body) do
      Logger.debug("Verified webhook payload for repository #{repo.id}")

      # mimic what Plug.Parsers does because we have the body, which can only be read once
      conn =
        conn
        |> Map.put(:body_params, body_params)
        |> Map.put(:params, Enum.into(body_params, conn.params))

      {:ok, conn}
    else
      _ ->
        {:error, :failed_to_verify}
    end
  end

  defp forge_header(%Sower.Forge.Connection{type: :forgejo}) do
    "x-forgejo-signature"
  end

  defp forge_header(%Sower.Forge.Connection{} = forge) do
    Logger.error("Unsupported forge webhook for #{forge.id}")
    "x-unsupported-forge-signature"
  end

  defp verify_payload(payload, shared_secret, received_signature) do
    signature =
      :crypto.mac(:hmac, :sha256, shared_secret, payload)
      |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(signature, received_signature)
  end

  defp send_unauthorized(conn) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> resp(401, %{error: "unauthorized"} |> Jason.encode!())
    |> send_resp()
    |> halt()
  end
end
