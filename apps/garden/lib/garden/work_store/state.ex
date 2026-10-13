defmodule Garden.WorkStore.Run do
  @moduledoc false
  use TypedStruct

  typedstruct do
    field :sid, String.t(), enforce: true
    field :inputs, [String.t()], default: []
    field :upstreams, [String.t()], default: []
    field :budget, non_neg_integer(), enforce: true
    field :outputs, [String.t()], default: []
    field :authorized, [String.t()], default: []
    field :used, non_neg_integer(), default: 0
  end
end

defmodule Garden.WorkStore.Data do
  @moduledoc false
  use TypedStruct

  typedstruct do
    field :options, keyword(), enforce: true
    field :runs, %{String.t() => Garden.WorkStore.Run.t()}, default: %{}
    field :objects, map(), default: %{}
    field :closed, MapSet.t(), default: MapSet.new()
    field :dirty, boolean(), default: false
  end
end

defmodule Garden.WorkStore.Transfer do
  @moduledoc false
  use TypedStruct

  typedstruct do
    field :service, pid(), enforce: true
    field :store, pid(), enforce: true
    field :guest, map(), enforce: true
    field :sockets, [String.t()], enforce: true
  end
end
