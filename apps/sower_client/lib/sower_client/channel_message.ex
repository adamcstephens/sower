defmodule SowerClient.ChannelMessage do
  @moduledoc """
  Defines the channel routing configuration for a schema.
  """

  @callback event() :: String.t()
  @callback topic_type() :: :private | :lobby

  defmacro __using__(opts) do
    quote do
      @behaviour SowerClient.ChannelMessage

      @impl SowerClient.ChannelMessage
      def event, do: unquote(Keyword.fetch!(opts, :event))

      @impl SowerClient.ChannelMessage
      def topic_type, do: unquote(Keyword.get(opts, :topic_type, :private))
    end
  end
end
