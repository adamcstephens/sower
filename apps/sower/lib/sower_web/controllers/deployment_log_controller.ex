defmodule SowerWeb.DeploymentLogController do
  use SowerWeb, :controller

  require Logger

  alias Sower.Orchestration
  alias Sower.Storage
  alias SowerClient.Orchestration.SeedDeployment

  @default_expiry_seconds 5 * 60

  def show(conn, params), do: show(conn, params, [])

  def show(conn, %{"sid" => deployment_sid, "seed_sid" => seed_sid}, opts) do
    with {:ok, deployment} <- fetch_deployment_with_seed(deployment_sid, seed_sid),
         object_path <- SeedDeployment.log_path(deployment.sid, seed_sid),
         {:ok, download_url} <- presign_download_url(object_path, opts) do
      redirect(conn, external: download_url)
    else
      {:error, :no_log} ->
        conn
        |> put_status(:not_found)
        |> text("no log")
        |> halt()

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
        |> halt()

      {:error, reason} ->
        Logger.error(
          msg: "Failed to fetch deployment log",
          deployment_sid: deployment_sid,
          seed_sid: seed_sid,
          reason: inspect(reason)
        )

        conn
        |> put_status(:internal_server_error)
        |> text("failed to load log")
        |> halt()
    end
  end

  defp fetch_deployment_with_seed(deployment_sid, seed_sid) do
    case Orchestration.get_deployment_sid(deployment_sid) do
      nil ->
        {:error, :not_found}

      deployment ->
        deployment = Sower.Repo.preload(deployment, :seeds)

        case Enum.any?(deployment.seeds, &(&1.sid == seed_sid)) do
          true -> {:ok, deployment}
          false -> {:error, :not_found}
        end
    end
  end

  defp presign_download_url(object_path, opts) do
    expiry_seconds = Keyword.get(opts, :expires_in, @default_expiry_seconds)
    presign_head_fun = Keyword.get(opts, :presign_head_fun, &Storage.presign_head/2)
    presign_download_fun = Keyword.get(opts, :presign_download_fun, &Storage.presign_download/2)
    req_head_fun = Keyword.get(opts, :req_head_fun, &Req.head/1)

    with {:ok, head_url} <- presign_head_fun.(object_path, expires_in: expiry_seconds),
         {:ok, %Req.Response{status: status}} when status >= 200 and status < 300 <-
           req_head_fun.(url: head_url, retry: false),
         {:ok, download_url} <- presign_download_fun.(object_path, expires_in: expiry_seconds) do
      {:ok, download_url}
    else
      {:ok, %Req.Response{status: status}} when status in [403, 404] ->
        {:error, :no_log}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
