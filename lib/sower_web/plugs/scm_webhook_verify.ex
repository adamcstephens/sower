defmodule SowerWeb.Plugs.ScmWebhookVerify do
  import Plug.Conn
  require Logger

  def init(options), do: options

  def call(%Plug.Conn{} = conn, _options) do
    scm_secret = Application.fetch_env!(:sower, :scm_secret)

    [received_signature] = get_req_header(conn, "x-forgejo-signature")
    Logger.info("x-forgejo-signature: " <> received_signature)

    if verify_signature(conn.assigns[:raw_body], scm_secret, received_signature) do
      Logger.info("Verified signature")
    else
      conn |> send_resp(403, "Forbidden") |> halt()
    end

    conn
  end

  def read_and_store_body(conn, opts) do
    {:ok, body, conn} = read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
    {:ok, body, conn}
  end

  defp verify_signature(payload, shared_secret, received_signature) do
    signature =
      :crypto.mac(:hmac, :sha256, shared_secret, payload)
      |> Base.encode16(case: :lower)

    Logger.info("hash result: " <> signature)

    Plug.Crypto.secure_compare(signature, received_signature)
  end
end
