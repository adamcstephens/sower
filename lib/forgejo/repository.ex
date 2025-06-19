defmodule Forgejo.Repository do
  def create_webhook(req, owner, repo, callback_url, secret) do
    case req
         |> Req.post(
           url: "/repos/#{owner}/#{repo}/hooks",
           json: %{
             type: "forgejo",
             config: %{url: callback_url, content_type: "json", secret: secret},
             active: true
           }
         ) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        {:ok, body}

      err ->
        err
    end
  end

  def delete_webhook(req, owner, repo, hook_id) do
    req |> Req.delete(url: "/repos/#{owner}/#{repo}/hooks/#{hook_id}")
  end

  def search(req, query) do
    case req |> Req.merge(params: [q: query]) |> Req.get(url: "repos/search") do
      {:ok, response} ->
        {:ok, response.body["data"]}

      error ->
        error
    end
  end
end
