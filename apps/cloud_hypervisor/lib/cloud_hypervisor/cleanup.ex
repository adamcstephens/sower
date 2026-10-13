defmodule CloudHypervisor.Cleanup do
  @moduledoc false

  def prepare(create_directory, resource_owner \\ nil) do
    server = self()
    reference = make_ref()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      monitor = Process.monitor(server)

      case create_directory.() do
        {:ok, directory} ->
          send(server, {reference, {:ok, self(), directory}})

          receive do
            {:run, run_reference, command} ->
              Process.demonitor(monitor, [:flush])
              run_execution(server, run_reference, command, directory, resource_owner)

            {:DOWN, ^monitor, :process, ^server, _reason} ->
              File.rmdir(directory)
          end

        {:error, _reason} = error ->
          send(server, {reference, error})
      end
    end)

    receive do
      {^reference, result} -> result
    end
  end

  def run(owner, command) do
    reference = make_ref()
    send(owner, {:run, reference, command})

    receive do
      {^reference, result} -> result
    end
  end

  defp run_execution(server, reference, command, directory, resource_owner) do
    case Rexec.run_link(command, owner: server) do
      {:ok, runner, os_pid} = result ->
        send(server, {reference, result})
        await_completion(server, runner, os_pid, directory, nil, resource_owner)

      {:error, reason} = result ->
        message =
          receive do
            {:cleanup_error, _os_pid, message} -> message
          after
            0 -> nil
          end

        error =
          if message do
            message
          else
            case File.rmdir(directory) do
              :ok ->
                nil

              {:error, failure} ->
                "Startup failed #{inspect(reason)}; execution directory removal failed " <>
                  "#{inspect(failure)} and process-tree cleanup is unconfirmed"
            end
          end

        if error, do: send(server, {:cleanup_error, nil, error})
        send(server, {reference, result})
    end
  end

  def completion(:normal), do: {:ok, {:exit_status, 0}}

  def completion({:shutdown, {kind, value}})
      when kind in [:exit_status, :signal] and is_integer(value),
      do: {:ok, {kind, value}}

  def completion({:shutdown, {:cleanup_failed, message}}), do: {:error, message}

  def completion(reason),
    do:
      {:error, "Rexec exited #{inspect(reason)} without confirming complete process-tree cleanup"}

  defp await_completion(server, runner, os_pid, directory, cleanup_error, resource_owner) do
    receive do
      {stream, ^os_pid, bytes} when stream in [:stdout, :stderr] ->
        send(server, {stream, os_pid, bytes})
        await_completion(server, runner, os_pid, directory, cleanup_error, resource_owner)

      {:cleanup_error, ^os_pid, message} ->
        send(server, {:cleanup_error, os_pid, message})

        await_completion(
          server,
          runner,
          os_pid,
          directory,
          cleanup_error || message,
          resource_owner
        )

      {:EXIT, ^runner, reason} ->
        result =
          case completion(reason) do
            {:ok, _outcome} when cleanup_error == nil ->
              case release_resources(directory, resource_owner) do
                :ok ->
                  reason

                {:error, failure} ->
                  {:shutdown,
                   {:cleanup_failed, "Execution resource removal failed: #{inspect(failure)}"}}
              end

            {:ok, _outcome} ->
              {:shutdown, {:cleanup_failed, cleanup_error}}

            {:error, message} ->
              {:shutdown, {:cleanup_failed, cleanup_error || message}}
          end

        send(server, {:EXIT, runner, result})
    end
  end

  defp release_resources(directory, nil), do: remove_resources(directory)

  defp release_resources(directory, owner) do
    reference = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {:cloud_hypervisor_cleanup, self(), reference, directory})

    result =
      receive do
        {^reference, :ok} -> remove_resources(directory)
        {^reference, {:error, reason}} -> {:error, {:external_cleanup, reason}}
        {:DOWN, ^monitor, :process, ^owner, reason} -> {:error, {:external_owner_down, reason}}
      after
        10_000 -> {:error, :external_cleanup_timeout}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp remove_resources(directory) do
    with :ok <- remove_resource(Path.join(directory, "api.sock")),
         :ok <- remove_resource(Path.join(directory, "api.sock") <> ".lock"),
         :ok <- remove_resource(Path.join(directory, "vsock.sock")),
         :ok <- File.rmdir(directory) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_resource(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
