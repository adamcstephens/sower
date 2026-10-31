defmodule VMManager.Config do
  use TypedStruct

  typedstruct do
    field :id, String.t(), enforce: true
    field :kernel, String.t()
    field :initrd, String.t()
    field :root, String.t()
    field :cmdline, String.t(), default: ""
    field :system, String.t(), default: "x86_64-linux"
    field :contract, integer(), default: 2
    field :vsock_port, pos_integer(), default: 5000
    field :cpus, pos_integer(), default: 1
    field :memory, pos_integer(), default: 536_870_912
    field :scratch_bytes, non_neg_integer(), default: 4_294_967_296
    field :disks, list(), default: []
    field :network, atom(), default: :none
    field :network_config, atom()
    field :network_lease, VMManager.Network.t()
    field :boot_deadline_ms, pos_integer(), default: 60_000
    field :runtime_directory, String.t()
    field :control_endpoint, String.t()
    field :guest_endpoint, String.t()
    field :runtime_identity, String.t()
    field :mode, atom(), default: :launch
    field :persistent_disks, [String.t()], default: []
    field :restart, atom(), default: :never
    field :restart_max_attempts, non_neg_integer(), default: 3
    field :restart_window_ms, pos_integer(), default: 60_000
    field :restart_delay_ms, non_neg_integer(), default: 1000
    field :mkfs, String.t(), default: "mkfs.ext4"
    field :hypervisor, String.t(), default: "cloud-hypervisor"
  end

  def validate(%__MODULE__{} = config) do
    cond do
      not is_binary(config.id) or not Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, config.id) ->
        {:error, :invalid_vm_id}

      not Enum.all?([config.kernel, config.initrd, config.root], &is_binary/1) ->
        {:error, :invalid_boot_artifacts}

      config.restart not in [:never, :on_failure, :always] ->
        {:error, :invalid_restart_policy}

      config.mode not in [:launch, :attach] ->
        {:error, :invalid_runtime_mode}

      config.mode == :attach and config.network == :full and
          not is_struct(config.network_lease, VMManager.Network) ->
        {:error, :missing_network_lease}

      config.network == :none and config.network_lease != nil ->
        {:error, :unexpected_network_lease}

      not Enum.all?(
        [config.cpus, config.memory, config.boot_deadline_ms, config.restart_window_ms],
        &(is_integer(&1) and &1 > 0)
      ) ->
        {:error, :invalid_resources}

      not Enum.all?(
        [config.scratch_bytes, config.restart_max_attempts, config.restart_delay_ms],
        &(is_integer(&1) and &1 >= 0)
      ) ->
        {:error, :invalid_resources}

      not serializable?(config) ->
        {:error, :non_serializable_configuration}

      true ->
        :ok
    end
  end

  def to_options(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.to_list()
    |> Keyword.merge(
      config: config,
      image: config,
      execution_id: config.id,
      resource_directory: config.runtime_directory
    )
  end

  defp serializable?(value)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
       do: false

  defp serializable?(value) when is_map(value),
    do: Enum.all?(Map.to_list(value), fn {k, v} -> serializable?(k) and serializable?(v) end)

  defp serializable?(value) when is_list(value), do: Enum.all?(value, &serializable?/1)

  defp serializable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(_value), do: true
end
