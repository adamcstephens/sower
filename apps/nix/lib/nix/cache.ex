defmodule Nix.Cache do
  @moduledoc """
  Behavior for binary cache upload backends.
  """

  @doc """
  Upload a batch of store paths to the configured cache.

  Returns `{:ok, result}` where result contains:
  - `:uploaded` - List of successfully uploaded paths
  - `:failed` - List of tuples `{path, reason}` for failures

  All paths in the input should appear in either `uploaded` or `failed`.

  For backends that upload all-or-nothing, a failure means all paths
  are in the `failed` list, while success means all are in `uploaded`.

  ## Examples

      {:ok, %{uploaded: ["/nix/store/abc-foo", "/nix/store/xyz-bar"], failed: []}}

      {:ok, %{uploaded: ["/nix/store/abc-foo"], failed: [{"/nix/store/xyz-bar", "permission denied"}]}}

      {:error, "invalid destination"}
  """
  @callback upload(paths :: [String.t()] | String.t(), config :: map()) ::
              {:ok, %{uploaded: [String.t()], failed: [{String.t(), term()}]}}
              | {:error, term()}

  @doc """
  Validate the backend configuration.

  Called before upload starts to fail fast on invalid config.

  ## Examples

      :ok

      {:error, "destination required"}
  """
  @callback validate_config(config :: map()) :: :ok | {:error, term()}

  @doc """
  Return a human-readable name for this backend.

  Used for logging and error messages.
  """
  @callback name() :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Nix.Cache

      defp ensure_store_paths(paths) when is_list(paths) do
        paths
        |> Enum.map(fn
          path when is_binary(path) -> path
          path when is_struct(path, Nix.Build) -> path.store_path
        end)
      end
    end
  end
end
