defmodule Garden.Socket.StatusTest do
  use ExUnit.Case, async: true

  test "rejects start observation while disconnected without accepting work" do
    socket = Slipstream.new_socket()
    sub = %SowerClient.Orchestration.Subscription{sid: "sub"}

    assert {:reply, {:error, :disconnected}, ^socket} =
             Garden.Socket.handle_call(
               {:observe_deployment, sub, false, self()},
               {self(), make_ref()},
               socket
             )
  end

  test "correlates async replies and deployment manifests by their request" do
    monitor = make_ref()
    watch = %Garden.DeploymentWait.Watch{pid: self(), monitor: monitor, ref: "ref-1"}

    socket =
      Slipstream.new_socket()
      |> Slipstream.Socket.assign(:garden_sid, "garden")
      |> Slipstream.Socket.assign(:active_deployments, %{})
      |> Slipstream.Socket.assign(:start_observers, %{"request-1" => watch})

    Garden.Socket.handle_reply("unrelated", :ok, socket)
    refute_received {:deployment_wait, _, _}
    Garden.Socket.handle_reply("ref-1", :ok, socket)
    assert_received {:deployment_wait, "request-1", :accepted}
    refute_received {:deployment_wait, _, {:started, _}}

    assert {:ok, updated} =
             Garden.Socket.handle_message(
               "garden:garden",
               "deployment",
               %{"request_id" => "request-1", "sid" => "dep", "seed_deployments" => []},
               socket
             )

    assert_received {:deployment_wait, "request-1", {:deployment, %{sid: "dep"}}}
    assert_received {:run_deployment, "dep"}

    assert {:noreply, cleaned} =
             Garden.Socket.handle_info({:DOWN, monitor, :process, self(), :normal}, updated)

    assert cleaned.assigns.start_observers == %{}
    assert Map.has_key?(cleaned.assigns.active_deployments, "dep")
  end

  test "empty pending replies finish observation without accepting deployment work" do
    watch = %Garden.DeploymentWait.Watch{pid: self(), monitor: make_ref(), ref: "ref"}

    socket =
      Slipstream.new_socket()
      |> Slipstream.Socket.assign(:start_observers, %{"request-1" => watch})

    Garden.Socket.handle_reply("ref", {:ok, %{"no_pending" => true}}, socket)
    assert_received {:deployment_wait, "request-1", :empty}
    refute_received {:deployment_wait, "request-1", :accepted}
  end

  test "forwards server rejection only to the matching request" do
    watch = %Garden.DeploymentWait.Watch{pid: self(), monitor: make_ref(), ref: "ref"}

    socket =
      Slipstream.new_socket()
      |> Slipstream.Socket.assign(:garden_sid, "garden")
      |> Slipstream.Socket.assign(:start_observers, %{"request-1" => watch})

    ExUnit.CaptureLog.capture_log(fn ->
      Garden.Socket.handle_message(
        "garden:garden",
        "deployment:error",
        %{"request_id" => "request-1", "reason" => "missing seed"},
        socket
      )
    end)

    assert_received {:deployment_wait, "request-1", {:rejected, "missing seed"}}
  end

  test "does not send deployment output to servers without log streaming support" do
    socket = Slipstream.new_socket()

    chunk = %SowerClient.Orchestration.SeedDeploymentLog{
      deployment_sid: "deployment",
      seed_sid: "seed",
      sequence: 1,
      output: "realizing\n"
    }

    assert {:reply, {:error, :unsupported}, ^socket} =
             Garden.Socket.handle_call({:deployment_log, chunk}, {self(), make_ref()}, socket)
  end

  test "does not request pending deployments from a server without the capability" do
    socket = Slipstream.new_socket()

    assert {:reply, nil, ^socket} =
             Garden.Socket.handle_call(:pending_deployments, {self(), make_ref()}, socket)
  end

  test "reports pending deployments as unknown while disconnected" do
    socket =
      Slipstream.new_socket() |> Slipstream.Socket.assign(:pending_deployments_supported, true)

    assert {:reply, nil, ^socket} =
             Garden.Socket.handle_call(:pending_deployments, {self(), make_ref()}, socket)
  end
end
