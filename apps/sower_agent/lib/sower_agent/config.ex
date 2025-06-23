defmodule SowerAgent.Config do
  use TypedStruct

  typedstruct do
    field :access_token, String.t()
  end

  # Could you define a behavior with different runtime/compiletime callbacks
  # with a simple Mod.func call in config which would be an entrypoint

  @app :sower_agent
  @env_prefix "SOWER_AGENT"

  def load(:prod) do
    %__MODULE__{
      access_token: read_env_file!("access_token_file")
    }
  end

  def load(:dev) do
    %__MODULE__{
      access_token: Application.fetch_env!(@app, :access_token_file) |> read_file()
    }
  end

  defp fetch_env!(name) do
    (@env_prefix <> name) |> String.upcase()
  end

  defp read_env_file!(name) do
    name |> fetch_env!() |> read_file()
  end

  defp read_file(path) do
    path |> File.read!() |> String.trim()
  end
end
