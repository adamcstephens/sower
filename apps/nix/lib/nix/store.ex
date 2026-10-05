defmodule Nix.Store do
  require Logger

  def realize(path) do
    Logger.debug(msg: "Realizing path", path: path)

    case System.find_executable("nix-store") do
      nil ->
        {:error, "nix-store command not found in PATH"}

      nix_store ->
        cmd = [nix_store, "--realize", path]

        Process.flag(:trap_exit, true)

        case Rexec.run_link(cmd) do
          {:ok, pid, ospid} ->
            collect_output(pid, ospid, [])

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp collect_output(pid, ospid, lines) do
    receive do
      {:stdout, ^ospid, data} ->
        IO.write(data)
        collect_output(pid, ospid, [data | lines])

      {:stderr, ^ospid, data} ->
        IO.write(:stderr, data)
        collect_output(pid, ospid, lines)

      {:EXIT, ^pid, :normal} ->
        {:ok, Enum.reverse(lines)}

      {:EXIT, ^pid, {:shutdown, {:exit_status, status}}} ->
        {:error, status}

      {:EXIT, ^pid, {:shutdown, {:signal, signal}}} ->
        {:error, {:signal, signal}}

      {:EXIT, ^pid, {:shutdown, {:cleanup_failed, message}}} ->
        {:error, {:cleanup_failed, message}}

      {:cleanup_error, ^ospid, message} ->
        {:error, {:cleanup_failed, message}}
    end
  end
end
