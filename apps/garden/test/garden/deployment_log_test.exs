defmodule Garden.DeploymentLogTest do
  use ExUnit.Case, async: true

  alias Garden.DeploymentLog
  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.SeedDeployment
  alias SowerClient.Orchestration.Subscription
  alias SowerClient.Seed

  test "splits large multibyte output into bounded valid UTF-8 chunks without losing bytes" do
    owner = self()
    log = DeploymentLog.start("dep", "seed", send_fun: &send(owner, {:chunk, &1}))
    output = String.duplicate("🌱é", 5_000)

    DeploymentLog.output(log, output)
    DeploymentLog.flush(log)

    chunks = receive_chunks([])
    assert Enum.map(chunks, & &1.sequence) == Enum.to_list(1..length(chunks))
    assert Enum.all?(chunks, &(byte_size(&1.output) <= 16_384 and String.valid?(&1.output)))
    assert Enum.map_join(chunks, & &1.output) == output <> "\n"
    DeploymentLog.stop(log)
  end

  test "flushes a partial batch while the command is still running" do
    owner = self()
    log = DeploymentLog.start("dep", "seed", send_fun: &send(owner, {:chunk, &1}))

    DeploymentLog.output(log, "building")
    assert_receive {:chunk, %{sequence: 1, output: "building\n"}}, 1_000
    DeploymentLog.output(log, "done")
    DeploymentLog.flush(log)
    assert_receive {:chunk, %{sequence: 2, output: "done\n"}}
    DeploymentLog.stop(log)
  end

  test "bounds queued bytes and does not block output on a stalled sender" do
    owner = self()

    log =
      DeploymentLog.start("dep", "seed",
        send_fun: fn chunk ->
          send(owner, {:sending, self(), chunk})

          receive do
            :continue -> :ok
          end
        end
      )

    on_exit(fn -> Process.exit(log.pid, :kill) end)
    DeploymentLog.output(log, String.duplicate("x", 16_383))
    assert_receive {:sending, sender, %{sequence: 1}}

    producer =
      Task.async(fn ->
        Enum.each(1..1_000, fn _ -> DeploymentLog.output(log, String.duplicate("y", 16_383)) end)
      end)

    assert Task.await(producer) == :ok
    assert :atomics.get(log.pending, 1) <= 65_536
    assert {:message_queue_len, count} = Process.info(log.pid, :message_queue_len)
    assert count <= 4
    Process.exit(sender, :kill)
  end

  test "streams actual command output across deployment phases and preserves final results offline" do
    owner = self()
    seed = %Seed{sid: "seed", name: "seed", seed_type: "nixos", artifact: "/unused"}
    deployment = %Deployment{sid: "dep", seed_deployments: [%SeedDeployment{seed: seed}]}

    result =
      Garden.Deployer.upgrade(deployment,
        async_stream_fun: fn enumerable, fun -> Enum.map(enumerable, &{:ok, fun.(&1)}) end,
        realize_seed_fun: fn seed_deployment, on_output ->
          {output, 0} = command_output("printf 'realizing\\nrealized\\n'", on_output)
          {:ok, seed_deployment, output}
        end,
        activate_seed_fun: fn _seed, _mode, on_output ->
          {output, 0} = command_output("printf 'activating\\nactivated\\n'", on_output)
          {:ok, output}
        end,
        find_subscription_fun: fn _ -> %Subscription{} end,
        garden_config_fun: fn -> %SowerClient.Config{} end,
        report_seed_status_fun: fn _, _, _ -> :ok end,
        report_seed_result_fun: fn _, _, status, output ->
          send(owner, {:result, status, output})
        end,
        send_log_fun: fn chunk ->
          send(owner, {:chunk, chunk})
          {:error, :disconnected}
        end
      )

    assert result == [{:ok, {:ok, ["activating", "activated"]}}]
    assert_receive {:result, :success, final_output}

    assert Enum.filter(
             final_output,
             &(&1 in ["realizing", "realized", "activating", "activated"])
           ) ==
             ["realizing", "realized", "activating", "activated"]

    assert [realization, activation] = receive_chunks([])
    assert {realization.sequence, realization.output} == {1, "realizing\nrealized\n"}
    assert {activation.sequence, activation.output} == {2, "activating\nactivated\n"}
  end

  test "collecting streamed command output preserves failure output and exit status" do
    owner = self()

    assert {["before failure", "failure detail"], 7} =
             command_output("printf 'before failure\\nfailure detail\\n'; exit 7", fn line ->
               send(owner, {:line, line})
             end)

    assert_receive {:line, "before failure"}
    assert_receive {:line, "failure detail"}
  end

  defp command_output(command, on_output) do
    System.cmd("sh", ["-c", command],
      into: %Garden.OutputCollector{on_output: on_output},
      lines: 1_024,
      stderr_to_stdout: true
    )
  end

  defp receive_chunks(acc) do
    receive do
      {:chunk, chunk} -> receive_chunks([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
