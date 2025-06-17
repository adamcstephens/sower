defmodule SowerClient do
  @moduledoc """

  """

  defmodule AgentHello do
    use TypedStruct

    @derive {Jason.Encoder, only: [:local_sid, :name]}

    typedstruct do
      plugin(TypedStructEctoChangeset)
      plugin(TypedStructCtor)

      field :agent_sid, String.t(), required: false
      field :local_sid, String.t()
      field :name, String.t()
    end
  end
end
