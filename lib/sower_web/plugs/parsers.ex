defmodule SowerWeb.Plugs.Parsers do
  require Logger

  @parser Plug.Parsers.init(
            parsers: [:urlencoded, :multipart, :json],
            pass: ["*/*"],
            json_decoder: Phoenix.json_library()
          )

  def init(opts), do: opts

  def call(conn, opts) do
    conditional_parsers(conn, opts)
  end

  # to validate webhooks we need the raw body, so skip parsers for webhooks
  defp conditional_parsers(
         %Plug.Conn{path_info: ["forges", _forge_id, "repos", _repo_id, "webhook" | _]} = conn,
         _opts
       ) do
    conn
  end

  defp conditional_parsers(conn, _opts) do
    Plug.Parsers.call(conn, @parser)
  end
end
