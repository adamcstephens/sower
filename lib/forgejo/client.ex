defmodule Forgejo.Client do
  def new(url, token) do
    url = String.trim_trailing(url, "/")

    Req.new(base_url: url <> "/api/v1", params: [limit: 50])
    |> Req.Request.put_header("Authorization", "token #{token}")
  end
end
