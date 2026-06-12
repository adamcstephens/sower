defmodule Nix.Cache.Niks3 do
  @moduledoc """
  Binary cache backend using niks3.

  niks3 uploads Nix store paths to an S3-compatible binary cache.
  Server URL and auth token are read from the environment
  (`NIKS3_SERVER_URL`, `NIKS3_AUTH_TOKEN_FILE` or
  `$XDG_CONFIG_HOME/niks3/auth-token`).

  ## Configuration

      %{}

  No configuration is required — all settings come from the environment.

  ## Example

      {:ok, result} = Nix.Cache.Niks3.upload([
        "/nix/store/abc123-foo",
        "/nix/store/xyz789-bar"
      ], %{})
  """

  use Nix.Cache

  require Logger

  @impl Nix.Cache
  def name(), do: "niks3"

  @impl Nix.Cache
  def validate_config(%{}), do: :ok

  @impl Nix.Cache
  def upload(path, config) when not is_list(path), do: upload([path], config)

  def upload(paths, _config) when is_list(paths) do
    if length(paths) == 0 do
      {:ok, %{uploaded: [], failed: []}}
    else
      paths = ensure_store_paths(paths)

      niks3_cmd = System.find_executable("niks3")

      if is_nil(niks3_cmd) do
        {:error, "niks3 command not found in PATH"}
      else
        do_upload(niks3_cmd, paths)
      end
    end
  end

  defp do_upload(niks3_cmd, paths) do
    args = ["push"] ++ paths

    Logger.debug(
      msg: "Uploading to cache",
      backend: "niks3",
      path_count: to_string(length(paths))
    )

    case System.cmd(niks3_cmd, args, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info(
          msg: "Upload succeeded",
          backend: "niks3",
          path_count: to_string(length(paths))
        )

        {:ok, %{uploaded: paths, failed: []}}

      {output, exit_code} ->
        Logger.error(
          msg: "Upload failed",
          backend: "niks3",
          exit_code: to_string(exit_code)
        )

        {:error, %Nix.Cache.UploadError{backend: "niks3", exit_code: exit_code, output: output}}
    end
  end
end
