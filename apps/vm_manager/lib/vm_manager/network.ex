defmodule VMManager.Network do
  @moduledoc false
  use TypedStruct

  typedstruct do
    field :ownership, :external | :managed, default: :external
    field :devices, [CloudHypervisor.Config.Net.t()], default: []
    field :provider, module()
    field :options, term(), default: []
    field :lease, term()
    field :cmdline, String.t(), default: ""
  end

  def valid?(nil), do: true

  def valid?(%__MODULE__{} = network) do
    is_list(network.devices) and
      Enum.all?(network.devices, &is_struct(&1, CloudHypervisor.Config.Net)) and
      is_binary(network.cmdline) and serializable?(network.options) and
      valid_custody?(network)
  end

  def valid?(_), do: false

  defp valid_custody?(%__MODULE__{ownership: :external} = network),
    do: is_nil(network.provider) and is_nil(network.lease)

  defp valid_custody?(%__MODULE__{ownership: :managed} = network) do
    is_atom(network.provider) and not is_nil(network.provider) and
      Code.ensure_loaded?(network.provider) and
      function_exported?(network.provider, :provision, 2) and
      function_exported?(network.provider, :revoke, 2) and
      function_exported?(network.provider, :release, 2) and
      serializable?(network.lease) and
      (not is_nil(network.lease) or (network.devices == [] and network.cmdline == ""))
  end

  defp valid_custody?(%__MODULE__{}), do: false

  defp serializable?(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: true

  defp serializable?([]), do: true
  defp serializable?([head | tail]), do: serializable?(head) and serializable?(tail)

  defp serializable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> serializable?(key) and serializable?(item) end)

  defp serializable?(_), do: false

  def provision(%VMManager.Config{}, allocation_id)
      when not is_binary(allocation_id) or byte_size(allocation_id) == 0 or
             byte_size(allocation_id) > 128,
      do: {:error, :invalid_network_allocation_id}

  def provision(%VMManager.Config{network: nil}, _allocation_id), do: {:ok, nil}

  def provision(
        %VMManager.Config{network: %__MODULE__{ownership: :external} = network},
        _allocation_id
      ),
      do: {:ok, network}

  def provision(%VMManager.Config{network: %__MODULE__{lease: lease} = network}, _allocation_id)
      when not is_nil(lease),
      do: {:ok, network}

  def provision(%VMManager.Config{} = config, allocation_id) do
    network = config.network
    network.provider.provision(allocation_id, network.options)
  end

  def devices(nil), do: []
  def devices(%__MODULE__{} = network), do: network.devices

  def cmdline(nil), do: ""
  def cmdline(%__MODULE__{} = network), do: network.cmdline

  def revoke(nil), do: :ok
  def revoke(%__MODULE__{ownership: :external}), do: :ok
  def revoke(%__MODULE__{lease: nil}), do: :ok

  def revoke(%__MODULE__{} = network),
    do: network.provider.revoke(network.lease, network.options)

  def release(nil), do: :ok
  def release(%__MODULE__{ownership: :external}), do: :ok
  def release(%__MODULE__{lease: nil}), do: :ok

  def release(%__MODULE__{} = network),
    do: network.provider.release(network.lease, network.options)
end
