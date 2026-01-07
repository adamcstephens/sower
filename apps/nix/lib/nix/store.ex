defmodule Nix.Store do
  require Logger

  def realize(path) do
    Logger.debug(msg: "Realizing path", path: path)

    cmd = ~c"nix-store --realize #{path}"

    Process.flag(:trap_exit, true)
    {:ok, pid, ospid} = :exec.run_link(cmd, [:stdout, :stderr])

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
