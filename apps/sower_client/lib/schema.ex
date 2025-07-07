defmodule SowerClient.Schema do
  defmacro __using__(_) do
    quote do
      alias OpenApiSpex.Schema
      require OpenApiSpex

      def cast(attrs \\ %{}) do
        OpenApiSpex.cast_value(attrs, schema())
      end

      def cast!(attrs \\ %{}) do
        {:ok, val} = OpenApiSpex.cast_value(attrs, schema())
        val
      end
    end
  end
end
