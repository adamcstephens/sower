defmodule Garden.Socket.StatusTest do
  use ExUnit.Case, async: true

  test "disconnected deployment requests preserve the socket for scheduled and admin callers" do
    socket = Slipstream.new_socket()

    subscription =
      SowerClient.Orchestration.Subscription.cast!(%{
        name: "host",
        sid: "disconnected-subscription",
        seed_name: "host",
        seed_type: "nixos"
      })

    assert {:noreply, ^socket} =
             Garden.Socket.handle_cast({:deployment_request, subscription, false}, socket)

    assert {:noreply, ^socket} =
             Garden.Socket.handle_cast({:deployment_request, subscription, true}, socket)
  end

  test "scheduled and admin requests cannot bypass managed capability or pending uninstall" do
    socket = Slipstream.new_socket()

    subscription =
      SowerClient.Orchestration.Subscription.cast!(%{
        name: "application",
        sid: "subscription",
        seed_name: "application",
        seed_type: "package"
      })

    assert {:noreply, ^socket} =
             Garden.Socket.handle_cast({:deployment_request, subscription, false}, socket)

    capable = Slipstream.Socket.assign(socket, :managed_profiles_supported, true)
    pending = %{subscription | uninstall_pending: true}

    assert {:noreply, ^capable} =
             Garden.Socket.handle_cast({:deployment_request, pending, true}, capable)
  end

  test "does not apply an incomplete subscription snapshot" do
    socket =
      Slipstream.new_socket()
      |> Slipstream.Socket.assign(:garden_sid, "garden")
      |> Slipstream.Socket.assign(:managed_profiles_supported, true)

    assert {:noreply, ^socket} =
             Garden.Socket.handle_message(
               "garden:garden",
               "subscriptions:refresh",
               %{"subscriptions" => [], "complete" => false},
               socket
             )
  end

  test "does not send managed operations to a server without the capability" do
    socket = Slipstream.new_socket()

    operation =
      SowerClient.Orchestration.ProfileOperation.cast!(%{
        request_id: "stage",
        profile_name: "application",
        subscription_sid: "subscription",
        action: "stage"
      })

    assert {:reply, {:error, :unsupported}, ^socket} =
             Garden.Socket.handle_call(
               {:profile_operation, operation},
               {self(), make_ref()},
               socket
             )
  end

  test "ignores managed commands from a server without negotiated capability" do
    socket = Slipstream.new_socket() |> Slipstream.Socket.assign(:garden_sid, "garden")

    assert {:noreply, ^socket} =
             Garden.Socket.handle_message(
               "garden:garden",
               "profile:operation",
               %{
                 "request_id" => "remove",
                 "profile_name" => "application",
                 "action" => "uninstall"
               },
               socket
             )
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
