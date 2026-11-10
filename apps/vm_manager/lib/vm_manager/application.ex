defmodule VMManager.Application do
  @moduledoc """
  Starts the VM manager registry and supervision tree.

  The default state directory is under `XDG_STATE_HOME`, or `~/.local/state`
  when unset. Application options can override it and the host boot identity file.
  """

  use Application

  @impl Application
  def start(_type, _arguments) do
    options = options(Application.get_all_env(:vm_manager))

    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: VMManager.Registry},
        {VMManager.Supervisor, Keyword.put(options, :name, VMManager.Supervisor)}
      ],
      strategy: :one_for_one,
      name: VMManager.ApplicationSupervisor
    )
  end

  def options(options) do
    state_home =
      System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")

    options = Keyword.put_new(options, :state_directory, Path.join(state_home, "vm-manager"))

    case System.get_env("VM_MANAGER_BOOT_ID_FILE") do
      nil -> options
      path -> Keyword.put_new(options, :boot_id_file, path)
    end
  end
end
