defmodule Sower.Storage do
  require Logger

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

  defp config() do
    Application.get_env(:sower, __MODULE__)
  end
end
