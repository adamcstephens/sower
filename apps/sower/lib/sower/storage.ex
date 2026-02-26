defmodule Sower.Storage do
  require Logger

  alias Sower.Orchestration
  alias Sower.Orchestration.Agent
  alias SowerClient.Storage.PresignedUploadReply
  alias SowerClient.Storage.DeploymentLogUploadRequest

  @doc """
  Generates a presigned URL for deployment log upload with authorization checks.

  Validates that:
  1. The deployment exists
  2. The deployment belongs to the requesting agent
  3. The seed is associated with the deployment

  Returns {:ok, PresignedUploadReply} on success, {:error, reason} on failure.
  """
  def presign_deployment_log_upload(
        %Agent{} = agent,
        %DeploymentLogUploadRequest{} = request,
        presign_upload_fun \\ &presign_upload/2
      ) do
    with {:ok, deployment} <- fetch_deployment(request.deployment_sid),
         :ok <- verify_deployment_ownership(deployment, agent),
         :ok <- verify_seed_in_deployment(deployment, request.seed_sid),
         object_path =
           SowerClient.Orchestration.SeedDeployment.log_path(
             request.deployment_sid,
             request.seed_sid
           ),
         {:ok, url} <- presign_upload_fun.(object_path, presign_upload_opts(request)) do
      {:ok,
       PresignedUploadReply.cast!(%{
         url: url,
         method: "PUT",
         headers: presign_upload_headers(request)
       })}
    else
      {:error, :deployment_not_found} ->
        {:error, :unauthorized}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, :seed_not_in_deployment} ->
        {:error, :seed_not_in_deployment}

      {:error, reason} ->
        Logger.error(
          msg: "Failed to presign deployment log upload",
          deployment_sid: request.deployment_sid,
          seed_sid: request.seed_sid,
          agent_sid: agent.sid,
          reason: inspect(reason)
        )

        {:error, :failed_to_presign_upload}
    end
  end

  defp fetch_deployment(deployment_sid) do
    case Orchestration.get_deployment_sid(deployment_sid) do
      nil -> {:error, :deployment_not_found}
      deployment -> {:ok, Sower.Repo.preload(deployment, :seeds)}
    end
  end

  defp verify_deployment_ownership(deployment, agent) do
    if deployment.agent_id == agent.id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp verify_seed_in_deployment(deployment, seed_sid) do
    if Enum.any?(deployment.seeds, &(&1.sid == seed_sid)) do
      :ok
    else
      {:error, :seed_not_in_deployment}
    end
  end

  def presign_upload(file, opts \\ []) do
    bucket = get_in(config(), [:s3, :bucket])
    expires_in = Keyword.get(opts, :expires_in, 60 * 60)
    headers = checksum_headers(opts) ++ Keyword.get(opts, :headers, [])

    Logger.debug(msg: "Generating presigned url", file: file, expires_in: expires_in)

    :s3
    |> ExAws.Config.new()
    |> ExAws.S3.presigned_url(:put, bucket, file,
      expires_in: expires_in,
      headers: headers
    )
  end

  def presign_download(file, opts \\ []) do
    bucket = get_in(config(), [:s3, :bucket])
    expires_in = Keyword.get(opts, :expires_in, 60 * 60)

    Logger.debug(msg: "Generating presigned download url", file: file, expires_in: expires_in)

    :s3
    |> ExAws.Config.new()
    |> ExAws.S3.presigned_url(:get, bucket, file, expires_in: expires_in)
  end

  def presign_head(file, opts \\ []) do
    bucket = get_in(config(), [:s3, :bucket])
    expires_in = Keyword.get(opts, :expires_in, 60 * 60)

    Logger.debug(msg: "Generating presigned head url", file: file, expires_in: expires_in)

    :s3
    |> ExAws.Config.new()
    |> ExAws.S3.presigned_url(:head, bucket, file, expires_in: expires_in)
  end

  defp checksum_headers(opts) do
    case Keyword.fetch(opts, :checksum_sha256) do
      {:ok, checksum} ->
        [{"x-amz-checksum-sha256", checksum}]

      :error ->
        []
    end
  end

  defp presign_upload_opts(%DeploymentLogUploadRequest{} = request) do
    case request.checksum_sha256 do
      nil -> []
      checksum -> [checksum_sha256: checksum]
    end
  end

  defp presign_upload_headers(%DeploymentLogUploadRequest{} = request) do
    case request.checksum_sha256 do
      nil -> %{}
      checksum -> %{"x-amz-checksum-sha256" => checksum}
    end
  end

  defp config() do
    Application.get_env(:sower, __MODULE__)
  end
end
