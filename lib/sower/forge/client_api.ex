defmodule Sower.Forge.ClientApi do
  @doc """
  Returns a req client for the forge type, given a forge and access token
  """
  def new(%Sower.Forge.Connection{type: :forgejo} = forge, token) do
    Forgejo.Client.new(forge.url, token)
  end

  def get_repos(req, %Sower.Forge.Connection{type: :forgejo} = _forge) do
    case Forgejo.User.get_repos(req) do
      {:ok, repos} ->
        {:ok,
         repos
         |> Enum.reject(& &1["archived"])
         |> Enum.sort_by(
           fn repo ->
             {:ok, updated_at, _} = DateTime.from_iso8601(repo["updated_at"])
             updated_at
           end,
           {:desc, DateTime}
         )}

      err ->
        err
    end
  end

  @doc """
  Registers a webhook for a repository in the remote forge
  """
  def register_repo_webhook(
        req,
        %Sower.Forge.Repository{forge: %Sower.Forge.Connection{type: :forgejo}} = repo
      ) do
    Forgejo.Repository.create_webhook(
      req,
      repo.owner,
      repo.repo,
      repo_webhook(repo),
      repo.webhook_secret
    )
  end

  @doc """
  De-registers a webhook for a repository in the remote forge
  """
  def deregister_repo_webhook(
        req,
        %Sower.Forge.Repository{forge: %Sower.Forge.Connection{type: :forgejo}} = repo
      ) do
    Forgejo.Repository.delete_webhook(req, repo.owner, repo.repo, repo.webhook_id)
  end

  defp repo_webhook(repo) do
    "#{Application.fetch_env!(:sower, :public_url)}/forges/#{repo.forge.id}/repos/#{repo.id}/webhook"
  end
end
