defmodule Forgejo.Client do
  def new(url, token) do
    url = String.trim_trailing(url, "/")

    Req.new(base_url: url <> "/api/v1", params: [limit: 50])
    |> Req.Request.put_header("Authorization", "token #{token}")
  end

  def get_user_repos(req) do
    case Req.get(req, url: "/user/repos") do
      {:ok, repos} ->
        {:ok,
         repos.body
         |> Enum.reject(& &1["archived"])
         |> Enum.sort_by(
           fn repo ->
             {:ok, updated_at, _} = DateTime.from_iso8601(repo["updated_at"])
             updated_at
           end,
           {:desc, DateTime}
         )}

      error ->
        error
    end
  end

  def search_repos(req, query) do
    case req |> Req.merge(params: [q: query]) |> Req.get(url: "repos/search") do
      {:ok, response} ->
        {:ok, response.body["data"]}

      error ->
        error
    end
  end
end
