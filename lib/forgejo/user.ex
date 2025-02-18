defmodule Forgejo.User do
  def get_repos(req) do
    case Req.get(req, url: "/user/repos") do
      {:ok, repos} ->
        {:ok, repos.body}

      error ->
        error
    end
  end
end
