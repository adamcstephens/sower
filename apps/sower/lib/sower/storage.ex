defmodule Sower.Storage do
  require Logger

  alias SowerClient.Storage.PresignUploadReply
  alias SowerClient.Storage.PresignUploadRequest

  def presign_upload(%PresignUploadRequest{} = request) do
    method = request.method || "PUT"

    if method != "PUT" do
      {:error, :unsupported_method}
    else
      opts = presign_upload_opts(request)

      case presign_upload(request.path, opts) do
        {:ok, url} ->
          {:ok,
           PresignUploadReply.cast!(%{
             url: url,
             method: method,
             headers: presign_upload_headers(request)
           })}

        {:error, reason} ->
          Logger.error(
            msg: "Failed to presign upload",
            path: request.path,
            method: method,
            reason: inspect(reason)
          )

          {:error, :failed_to_presign_upload}
      end
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

  defp presign_upload_opts(%PresignUploadRequest{} = request) do
    case request.checksum_sha256 do
      nil -> []
      checksum -> [checksum_sha256: checksum]
    end
  end

  defp presign_upload_headers(%PresignUploadRequest{} = request) do
    case request.checksum_sha256 do
      nil -> %{}
      checksum -> %{"x-amz-checksum-sha256" => checksum}
    end
  end

  defp config() do
    Application.get_env(:sower, __MODULE__)
  end
end
