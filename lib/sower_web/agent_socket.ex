defmodule SowerWeb.AgentSocket do
  require Logger
  use Phoenix.Socket

  channel("agent:*", SowerWeb.AgentChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # TODO replace with access token
    bootstrap_token =
      case Application.fetch_env(:sower, :bootstrap_token) do
        {:ok, token} -> token
        :error -> Kernel.exit(:config_no_bootstrap_token)
      end

    signer = Joken.Signer.create("HS256", bootstrap_token)

    case Joken.Signer.verify(token, signer) do
      {:ok, claims} ->
        {:ok, socket |> assign(:claims, claims)}

      _ ->
        Logger.error("failed to verify agent token")
        {:error, "unauthorized"}
    end
  end

  def connect(%{}, socket, _connect_info) do
    Logger.error(msg: "TODO non-authorized connection")
    {:ok, assign(socket, :sid, Sower.Schema.Sid.generate())}
  end

  def connect(%{}, _socket, _connect_info) do
    Logger.debug(msg: "unauthorized connection")
    {:error, "unauthorized. authentication token required"}
  end

  @impl true
  def id(_socket), do: nil
end
