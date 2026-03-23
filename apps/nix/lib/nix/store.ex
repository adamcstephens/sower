defmodule Nix.Store do
  require Logger

  def realize(path) do
    Logger.debug(msg: "Realizing path", path: path)

    cmd = [System.find_executable("nix-store"), "--realize", path]

    Process.flag(:trap_exit, true)
    {:ok, pid, ospid} = Rexec.run_link(cmd)

    collect_output(pid, ospid, [])
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

      {:EXIT, ^pid, {:exit_status, status}} ->
        {:error, status}
    end
  end
end
