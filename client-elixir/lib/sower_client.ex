defmodule SowerClient do
  @moduledoc """

  """

  defmodule AgentHello do
    use TypedStruct

    @derive {Jason.Encoder, only: [:local_sid, :name]}

    typedstruct do
      plugin(TypedStructEctoChangeset)
      plugin(TypedStructCtor, required: false)

      field :local_sid, String.t()
      field :name, String.t(), enforce: true
    end
  end
end
