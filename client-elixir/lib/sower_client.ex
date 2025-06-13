defmodule SowerClient do
  @moduledoc """

  """

  defmodule Agent do
    use TypedStruct

    @derive {Jason.Encoder, only: [:sid, :name]}

    typedstruct do
      plugin(TypedStructEctoChangeset)
      plugin(TypedStructCtor, required: false)

      field :sid, String.t()
      field :name, String.t(), enforce: true
    end
  end
end
