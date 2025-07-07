defmodule SowerClient.Schema do
  defmacro __using__(_) do
    quote do
      def cast(attrs \\ %{}) do
        OpenApiSpex.cast_value(attrs, schema())
      end

      def cast!(attrs \\ %{}) do
        OpenApiSpex.cast_value(attrs, schema())
        |> then(fn {:ok, val} -> val end)
      end
    end
  end
end
