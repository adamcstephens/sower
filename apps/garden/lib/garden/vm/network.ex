defmodule Garden.VM.Network do
  @moduledoc false
  use TypedStruct

  typedstruct do
    field :socket_path, String.t(), enforce: true
    field :lease, String.t(), enforce: true
    field :tap, String.t(), enforce: true
    field :mac, String.t(), enforce: true
    field :address, String.t(), enforce: true
    field :gateway, String.t(), enforce: true
    field :dns, String.t(), enforce: true
  end

  def provision(options) do
    case Keyword.get(options, :network, :none) do
      :none ->
        {:ok, nil}

      :full ->
        socket_path =
          Keyword.get(options, :activator_socket, "/run/sower-activator/activator.sock")

        execution_id =
          to_string(
            Keyword.get(options, :execution_id, "local-#{System.unique_integer([:positive])}")
          )

        case Garden.ActivatorClient.network(:provision,
               socket_path: socket_path,
               execution_id: execution_id
             ) do
          {:ok, lease} ->
            {:ok,
             %__MODULE__{
               socket_path: socket_path,
               lease: lease.lease,
               tap: lease.tap,
               mac: lease.mac,
               address: lease.address,
               gateway: lease.gateway,
               dns: lease.dns
             }}

          {:error, :socket_not_found} ->
            {:error, {:network_connect, :enoent}}

          {:error, :connection_refused} ->
            {:error, {:network_connect, :econnrefused}}

          {:error, reason} ->
            {:error, {:network_provision_unconfirmed, reason}}
        end
    end
  end

  def revoke(nil), do: :ok
  def revoke(%__MODULE__{} = network), do: operation(network, :revoke)
  def release(nil), do: :ok
  def release(%__MODULE__{} = network), do: operation(network, :release)

  defp operation(%__MODULE__{} = network, action) do
    Garden.ActivatorClient.network(action, socket_path: network.socket_path, lease: network.lease)
  end

  def devices(nil), do: []

  def devices(%__MODULE__{} = network),
    do: [%CloudHypervisor.Config.Net{tap: network.tap, mac: network.mac}]

  def cmdline(nil), do: ""

  def cmdline(%__MODULE__{} = network) do
    " sower.network.address=#{network.address} sower.network.gateway=#{network.gateway}" <>
      " sower.network.dns=#{network.dns} sower.network.mac=#{network.mac}"
  end
end
