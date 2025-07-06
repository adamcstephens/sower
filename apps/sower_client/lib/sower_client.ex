defmodule SowerClient do
  @moduledoc """

  """

  defmodule AgentHello do
    use Xema

    @derive {Jason.Encoder, only: [:agent_sid, :local_sid, :name]}

    xema_struct do
      field :agent_sid, :string
      field :local_sid, :string
      field :name, :string

      required [:local_sid, :name]
    end
  end
end
