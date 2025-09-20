defmodule SowerAgent.TaskRunner do
  require Logger

  def upgrade(seeds) do
    seeds
    |> async_stream(fn seed ->
      Logger.debug(
        msg: "Realizing seed",
        name: seed.name,
        seed_sid: seed.sid,
        seed_type: seed.seed_type,
        artifact: seed.artifact
      )

      case System.cmd("nix-store", ["--realize", seed.artifact],
             stderr_to_stdout: true,
             into: [],
             lines: 1024
           ) do
        {_output, 0} ->
          Logger.info(
            msg: "Successfully realized seed",
            name: seed.name,
            seed_sid: seed.sid,
            seed_type: seed.seed_type,
            artifact: seed.artifact
          )

          {:ok, seed}

        {output, exit_code} ->
          output =
            Enum.filter(output, fn line ->
              line not in [
                "warning: you did not specify '--add-root'; the result might be removed by the garbage collector"
              ]
            end)

          Logger.error(
            msg: "Failed to realize seed",
            name: seed.name,
            seed_sid: seed.sid,
            seed_type: seed.seed_type,
            artifact: seed.artifact,
            exit_code: exit_code,
            output: output
          )

          {:error, :failed_to_realize, seed}
      end
    end)
    |> async_stream(fn
      {:ok, {:ok, seed}} ->
        Logger.info(
          msg: "Activating seed",
          name: seed.name,
          seed_sid: seed.sid,
          seed_type: seed.seed_type,
          artifact: seed.artifact
        )

        SowerAgent.Seed.activate(seed)

      {:ok, {:error, _, _} = error} ->
        error

      {:exit, error} ->
        error
    end)
    |> Enum.to_list()
  end

  def async_stream(enumerable, func) do
    Task.Supervisor.async_stream_nolink(SowerAgent.TaskSupervisor, enumerable, func,
      max_concurrency: 3
    )
  end
end
