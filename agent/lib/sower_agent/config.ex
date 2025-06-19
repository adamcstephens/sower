defmodule SowerAgent.Config do
  use TypedStruct

  typedstruct do
    field :access_token, String.t()
  end

  def load() do
    %__MODULE__{
      access_token:
        System.fetch_env!("SOWER_AGENT_ACCESS_TOKEN_FILE") |> File.read!() |> String.trim()
    }
  end
end
