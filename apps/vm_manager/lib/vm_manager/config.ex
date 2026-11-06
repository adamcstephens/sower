defmodule VMManager.Config do
  use TypedStruct

  typedstruct module: SowerGuest do
    field :contract, integer(), default: 2
    field :vsock_port, pos_integer(), default: 5000
  end

  typedstruct do
    field :id, String.t(), enforce: true
    field :kernel, String.t()
    field :initrd, String.t()
    field :guest, :none | SowerGuest.t(), default: :none
    field :cmdline, String.t(), default: ""
    field :system, String.t(), default: "x86_64-linux"
    field :serial, CloudHypervisor.Config.Output.t()
    field :console, CloudHypervisor.Config.Output.t()
    field :rng, CloudHypervisor.Config.RNG.t()
    field :vsock, CloudHypervisor.Config.Vsock.t()
    field :cpus, pos_integer(), default: 1
    field :memory, pos_integer(), default: 536_870_912
    field :disks, list(), default: []
    field :network, VMManager.Network.t()
    field :boot_deadline_ms, pos_integer(), default: 60_000
    field :runtime_directory, String.t()
    field :control_endpoint, String.t()
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

      not is_binary(config.kernel) or
          not (is_nil(config.initrd) or is_binary(config.initrd)) ->
        {:error, :invalid_boot_artifacts}

      config.system != "x86_64-linux" ->
        {:error, :unsupported_system}

      config.guest != :none and
          not match?(
            %SowerGuest{contract: contract, vsock_port: 5000} when contract in [1, 2],
            config.guest
          ) ->
        {:error, :unsupported_guest}

      not VMManager.Storage.valid?(config) ->
        {:error, :invalid_storage}

      not VMManager.Network.valid?(config.network) ->
        {:error, {:invalid_option, :network}}

      config.mode == :launch and
          match?(%{ownership: :managed, lease: lease} when not is_nil(lease), config.network) ->
        {:error, :unexpected_network_lease}

      config.mode == :attach and match?(%{ownership: :managed, lease: nil}, config.network) ->
        {:error, :missing_network_lease}

      config.guest != :none and not is_struct(config.vsock, CloudHypervisor.Config.Vsock) ->
        {:error, :missing_guest_vsock}

      config.restart not in [:never, :on_failure, :always] ->
        {:error, :invalid_restart_policy}

      config.mode not in [:launch, :attach] ->
        {:error, :invalid_runtime_mode}

      not valid_output?(config.serial) or not valid_output?(config.console) or
          match?(%CloudHypervisor.Config.Output{mode: :socket}, config.console) ->
        {:error, :invalid_output}

      not VMManager.Storage.distinct_paths?(config) ->
        {:error, :invalid_storage}

      config.mode == :attach and
          (Enum.any?(config.disks, &is_struct(&1, VMManager.Storage.EphemeralDisk)) or
             Enum.any?([config.serial, config.console], fn
               %CloudHypervisor.Config.Output{mode: :file} = output ->
                 Path.type(output.file) != :absolute

               _ ->
                 false
             end)) ->
        {:error, :invalid_attachment_layout}

      config.rng != nil and not is_struct(config.rng, CloudHypervisor.Config.RNG) ->
        {:error, :invalid_rng}

      config.vsock != nil and not is_struct(config.vsock, CloudHypervisor.Config.Vsock) ->
        {:error, :invalid_vsock}

      config.mode == :launch and
          match?(%{socket: socket} when not is_nil(socket), config.vsock) ->
        {:error, :invalid_vsock}

      config.mode == :attach and
          (not is_binary(config.control_endpoint) or
             match?(%{socket: socket} when not is_binary(socket), config.vsock)) ->
        {:error, :invalid_attachment_layout}

      not Enum.all?(
        [
          config.cpus,
          config.memory,
          config.boot_deadline_ms,
          config.restart_window_ms
        ],
        &(is_integer(&1) and &1 > 0)
      ) ->
        {:error, :invalid_resources}

      not Enum.all?(
        [config.restart_max_attempts, config.restart_delay_ms],
        &(is_integer(&1) and &1 >= 0)
      ) ->
        {:error, :invalid_resources}

      not VMManager.Serialization.serializable?(config) ->
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
      execution_id: config.id,
      resource_directory: config.runtime_directory
    )
  end

  defp valid_output?(nil), do: true

  defp valid_output?(%CloudHypervisor.Config.Output{mode: :file} = output),
    do: VMManager.Storage.valid_output_file?(output.file)

  defp valid_output?(%CloudHypervisor.Config.Output{mode: :socket} = output),
    do: is_binary(output.socket)

  defp valid_output?(%CloudHypervisor.Config.Output{} = output),
    do: output.mode in [:off, :null, :tty, :pty]

  defp valid_output?(_output), do: false
end
