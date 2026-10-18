defmodule Garden.OutputCollector do
  use TypedStruct

  typedstruct do
    field :on_output, function(), enforce: true
  end
end

defimpl Collectable, for: Garden.OutputCollector do
  def into(%Garden.OutputCollector{} = collector) do
    {[],
     fn
       output, {:cont, line} ->
         collector.on_output.(line)
         [line | output]

       output, :done ->
         Enum.reverse(output)

       _output, :halt ->
         :ok
     end}
  end
end
