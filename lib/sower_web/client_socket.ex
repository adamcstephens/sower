defmodule SowerWeb.ClientSocket do
  require Logger
  use Phoenix.Socket

  channel("client:*", SowerWeb.ClientChannel)

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
        Logger.error("failed to verify client token")
        {:error, "unauthorized"}
    end
  end

  def connect(%{}, _socket, _connect_info) do
    {:error, "unauthorized. authentication token required"}
  end

  @impl true
  def id(_socket), do: nil
end
