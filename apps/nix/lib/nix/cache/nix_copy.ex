defmodule Nix.Cache.NixCopy do
  @moduledoc """
  Binary cache backend using `nix copy`.

  Supports uploading to various destinations:
  - SSH: `ssh://user@host`
  - S3: `s3://bucket-name` (requires AWS credentials configured)
  - HTTP: `http://cache.example.com` or `https://cache.example.com`
  - Local: `file:///path/to/cache`

  ## Configuration

      %{destination: "ssh://user@host/nix-cache"}
      %{destination: "s3://my-bucket"}
      %{destination: "https://cache.example.com"}

  ## Example

      config = %{destination: "ssh://builder@cache.example.com"}
      {:ok, result} = Nix.Cache.NixCopy.upload(config, [
        "/nix/store/abc123-foo",
        "/nix/store/xyz789-bar"
      ])
  """

  use Nix.Cache

  require Logger

  @impl Nix.Cache
  def name(), do: "nix copy"

  @impl Nix.Cache
  def validate_config(%{destination: dest}) when is_binary(dest) and byte_size(dest) > 0 do
    :ok
  end

  def validate_config(_) do
    {:error, "destination required (e.g., ssh://host, s3://bucket, https://cache)"}
  end

  @impl Nix.Cache
  def upload(path, config) when not is_list(path), do: upload([path], config)

  def upload(paths, %{destination: dest}) when is_list(paths) do
    if length(paths) == 0 do
      {:ok, %{uploaded: [], failed: []}}
    else
      nix_cmd = System.find_executable("nix")
      paths = ensure_store_paths(paths)

      if is_nil(nix_cmd) do
        {:error, "nix command not found in PATH"}
      else
        args = ["copy", "--to", dest] ++ paths

        Logger.debug(
          msg: "Uploading to cache",
          backend: "nix copy",
          destination: dest,
          path_count: length(paths)
        )

        case System.cmd(nix_cmd, args, stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.info(
              msg: "Upload succeeded",
              backend: "nix copy",
              destination: dest,
              path_count: length(paths)
            )

            {:ok, %{uploaded: paths, failed: []}}

          {output, exit_code} ->
            # nix copy is all-or-nothing - if it fails, all paths failed
            Logger.error(
              msg: "Upload failed",
              backend: "nix copy",
              destination: dest,
              exit_code: to_string(exit_code)
            )

            {:error,
             %Nix.Cache.UploadError{backend: "nix copy", exit_code: exit_code, output: output}}
        end
      end
    end
  end
end
