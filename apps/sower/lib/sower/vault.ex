defmodule Sower.Vault do
  use Cloak.Vault, otp_app: :sower

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: get_key()}
      )

    {:ok, config}
  end

  defp get_key() do
    Application.fetch_env!(:sower, :database) |> Keyword.fetch!(:encryption_key)
  end
end
