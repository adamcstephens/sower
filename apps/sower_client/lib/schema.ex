defmodule SowerClient.Schema do
  defmacro __using__(_) do
    quote do
      alias OpenApiSpex.Schema
      require OpenApiSpex

      def cast(attrs \\ %{}) do
        spec = SowerClient.spec()
        resolved_schema = spec.components.schemas[schema().title]
        OpenApiSpex.cast_value(attrs, resolved_schema, spec)
      end

      def cast!(attrs \\ %{}) do
        {:ok, val} = cast(attrs)
        val
      end
    end
  end
end
