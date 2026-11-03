defmodule Garden.VM.Network do
  @moduledoc false

  alias VMManager.Network

  def request(options \\ []) do
    %Network{
      ownership: :managed,
      provider: __MODULE__,
      options: [
        socket_path:
          Keyword.get_lazy(options, :socket_path, fn ->
            Application.get_env(:garden, :activator_socket, "/run/sower-activator/activator.sock")
          end)
      ]
    }
  end

  def provision(id, options) do
    case Garden.ActivatorClient.network(:provision, Keyword.put(options, :execution_id, id)) do
      {:ok, lease} ->
        {:ok,
         %Network{
           ownership: :managed,
           provider: __MODULE__,
           options: options,
           lease: lease.lease,
           devices: [%CloudHypervisor.Config.Net{tap: lease.tap, mac: lease.mac}],
           cmdline:
             " sower.network.address=#{lease.address} sower.network.gateway=#{lease.gateway}" <>
               " sower.network.dns=#{lease.dns} sower.network.mac=#{lease.mac}"
         }}

      {:error, :socket_not_found} ->
        {:error, {:network_connect, :enoent}}

      {:error, :connection_refused} ->
        {:error, {:network_connect, :econnrefused}}

      {:error, reason} ->
        {:error, {:network_provision_unconfirmed, reason}}
    end
  end

  def revoke(lease, options),
    do: Garden.ActivatorClient.network(:revoke, Keyword.put(options, :lease, lease))

  def release(lease, options),
    do: Garden.ActivatorClient.network(:release, Keyword.put(options, :lease, lease))
end
