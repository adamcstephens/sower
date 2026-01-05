defmodule SowerAgent.ChannelClient do
  @moduledoc """
  Shared Slipstream client helpers.

  Use this module from a consumer-specific socket client to get the default
  client interface along with generic Slipstream callbacks. Override the
  callbacks you need in the consumer module to customize behavior.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Slipstream
      require Logger

      @lobby_topic Keyword.fetch!(opts, :lobby_topic)

      #
      # client
      #

      def call(message) do
        GenServer.call(__MODULE__, message)
      end

      def call(event, params) do
        GenServer.call(__MODULE__, {event, params})
      end

      def cast(event) when is_atom(event) do
        GenServer.cast(__MODULE__, event)
      end

      def cast(event, params) do
        GenServer.cast(__MODULE__, {event, params})
      end

      def restart() do
        GenServer.stop(__MODULE__, :shutdown)
      end

      def lobby_topic, do: @lobby_topic

      #
      # Slipstream callbacks
      #

      @impl Slipstream
      def handle_call(:ping, _from, socket) do
        {:ok, ref} = push(socket, lobby_topic(), "ping", %{})
        {:ok, "pong"} = await_reply(ref)
        {:reply, {:ok, :pong}, socket}
      end

      def handle_call({event, params}, _from, socket) do
        {:ok, ref} = push(socket, private_channel(socket), event, params)
        {:reply, await_reply(ref), socket}
      end

      def handle_call(request, from, socket) do
        Logger.error(msg: "Unsupported call", request: request, from: from)
        {:reply, {:error, :unsupported_request}, socket}
      end

      @impl Slipstream
      def handle_cast({event, params}, socket) do
        {:ok, _} = push(socket, private_channel(socket), event, params)
        {:noreply, socket}
      end

      def handle_cast(message, socket) do
        Logger.error(msg: "Unsupported cast", message: message)
        {:noreply, socket}
      end

      def start_link(args) do
        Slipstream.start_link(__MODULE__, args, name: __MODULE__)
      end

      @impl Slipstream
      def init(_args) do
        config = Application.get_all_env(__MODULE__)

        case connect(config) do
          {:ok, socket} ->
            Logger.debug(msg: "Connecting")
            {:ok, socket}

          {:error, reason} ->
            Logger.error(
              "Could not start #{__MODULE__} because of " <>
                "validation failure: #{inspect(reason)}"
            )

            :ignore
        end
      end

      @impl Slipstream
      def handle_connect(socket) do
        Logger.info(
          msg: "Connected to websocket",
          authority: socket.channel_config.uri.authority,
          path: socket.channel_config.uri.path
        )

        {:ok, join(socket, lobby_topic())}
      end

      @impl Slipstream
      def handle_join(topic, _params, socket) do
        Logger.info(msg: "Joined channel topic", topic: topic)
        {:ok, socket}
      end

      @impl Slipstream
      def handle_message(topic, message, params, socket) do
        Logger.debug(
          msg: "Received unknown message",
          topic: topic,
          message: message,
          params: params
        )

        {:noreply, socket}
      end

      @impl Slipstream
      def handle_reply(_ref, :ok, socket) do
        {:noreply, socket}
      end

      def handle_reply(ref, payload, socket) do
        Logger.debug(msg: "Received unknown reply", ref: ref, payload: payload)
        {:noreply, socket}
      end

      def private_channel(%{assigns: %{private_topic: topic}}) when is_binary(topic) do
        topic
      end

      def private_channel(_socket) do
        raise ArgumentError, "Assign :private_topic or override private_channel/1"
      end

      def push_message(socket, %module{} = struct) do
        event = module.event()

        topic =
          case module.topic_type() do
            :private -> private_channel(socket)
            :lobby -> lobby_topic()
          end

        push(socket, topic, event, struct)
      end

      defoverridable handle_call: 3,
                     handle_cast: 2,
                     init: 1,
                     handle_connect: 1,
                     handle_join: 3,
                     handle_message: 4,
                     handle_reply: 3,
                     private_channel: 1,
                     push_message: 2
    end
  end
end
