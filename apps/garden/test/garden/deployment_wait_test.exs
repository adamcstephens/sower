defmodule Garden.DeploymentWaitTest do
  use ExUnit.Case, async: true

  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.Subscription

  test "waits for every matching seed worker, not acceptance or deployment receipt" do
    parent = self()
    request = "request-1"
    deployment = deployment(request)

    waiter =
      spawn(fn ->
        result =
          Garden.DeploymentWait.observe(request, subscription(), 1000, fn kind, text ->
            send(parent, {kind, text})
            :ok
          end)

        send(parent, {:finished, result})
      end)

    send(waiter, {:deployment_wait, "other-request", {:started, "seed-a"}})
    send(waiter, {:deployment_wait, request, :accepted})
    send(waiter, {:deployment_wait, request, {:deployment, deployment}})
    assert_receive {:ok, "enqueued 2 seeds"}
    assert_receive {:ok, "enqueued host (nixos), deployment dep-1, seed seed-a"}
    assert_receive {:ok, "enqueued user (home-manager), deployment dep-1, seed seed-b"}
    refute_receive {:finished, _}, 20
    send(waiter, {:deployment_wait, request, {:started, "seed-a"}})
    assert_receive {:ok, "started host (nixos), deployment dep-1"}
    refute_receive {:finished, _}, 20
    send(waiter, {:deployment_wait, request, {:started, "seed-b"}})
    assert_receive {:ok, "started user (home-manager), deployment dep-1"}
    assert_receive {:finished, 0}
  end

  test "timeout reports every unconfirmed seed and does not claim failed execution" do
    send(self(), {:deployment_wait, "request-1", {:deployment, deployment("request-1")}})
    send(self(), {:deployment_wait, "request-1", {:started, "seed-a"}})
    parent = self()

    assert 1 =
             Garden.DeploymentWait.observe("request-1", subscription(), 10, fn kind, text ->
               send(parent, {kind, text})
               :ok
             end)

    assert_receive {:error,
                    "start unconfirmed user (home-manager), deployment dep-1: timed out; work may still run"}

    refute_receive {:error, "start unconfirmed host" <> _}
  end

  test "rejection before a manifest identifies the subscription without inventing a deployment id" do
    send(self(), {:deployment_wait, "request-1", {:rejected, "no seed available"}})
    parent = self()

    assert 1 =
             Garden.DeploymentWait.observe("request-1", subscription(), 1000, fn kind, text ->
               send(parent, {kind, text})
               :ok
             end)

    assert_receive {:error,
                    "failed-to-start host (nixos), request request-1, deployment unavailable: no seed available"}
  end

  test "retains early starts and observes local workers after a server disconnect" do
    send(self(), {:deployment_wait, "request-1", {:started, "seed-a"}})
    send(self(), {:deployment_wait, "request-1", {:deployment, deployment("request-1")}})
    send(self(), {:deployment_wait, "request-1", :disconnected})
    send(self(), {:DOWN, make_ref(), :process, self(), :disconnected})
    send(self(), {:deployment_wait, "request-1", {:started, "seed-b"}})
    parent = self()

    assert 0 =
             Garden.DeploymentWait.observe("request-1", subscription(), 1000, fn kind, text ->
               send(parent, {kind, text})
               :ok
             end)

    assert_received {:ok, "started host (nixos), deployment dep-1"}
    assert_received {:ok, "started user (home-manager), deployment dep-1"}
    refute_received {:error, _}
  end

  test "disconnect before dispatch is unconfirmed, not failed-to-start" do
    send(self(), {:deployment_wait, "request-1", :disconnected})
    parent = self()

    assert 1 =
             Garden.DeploymentWait.observe("request-1", subscription(), 1000, fn kind, text ->
               send(parent, {kind, text})
               :ok
             end)

    assert_received {:error, "start unconfirmed host (nixos)" <> _}
  end

  test "skipped deployment never reports started" do
    send(
      self(),
      {:deployment_wait, "request-1", {:deployment, %{deployment("request-1") | skipped: true}}}
    )

    parent = self()

    assert 1 =
             Garden.DeploymentWait.observe("request-1", subscription(), 1000, fn kind, text ->
               send(parent, {kind, text})
               :ok
             end)

    assert_received {:error,
                     "failed-to-start host (nixos), deployment dep-1: skipped; already deployed"}

    assert_received {:error,
                     "failed-to-start user (home-manager), deployment dep-1: skipped; already deployed"}

    refute_received {:ok, "started" <> _}
    refute_received {:ok, "enqueued" <> _}
  end

  test "client disconnect stops observation without cancelling work" do
    send(self(), {:tcp_closed, :client})

    assert 1 =
             Garden.DeploymentWait.observe("request-1", subscription(), 1000, fn _, _ -> :ok end)
  end

  test "no-wait requires the actual manifest but does not wait for workers" do
    parent = self()

    waiter =
      spawn(fn ->
        result =
          Garden.DeploymentWait.observe(
            "request-1",
            nil,
            1000,
            fn kind, text -> send(parent, {kind, text}) end,
            false
          )

        send(parent, {:finished, result})
      end)

    send(waiter, {:deployment_wait, "request-1", :accepted})
    refute_receive {:finished, _}, 20
    refute_receive {:ok, "enqueued" <> _}, 20
    send(waiter, {:deployment_wait, "request-1", {:deployment, deployment("request-1")}})
    assert_receive {:ok, "enqueued 2 seeds"}
    assert_receive {:finished, 0}
    refute_receive {:ok, "started" <> _}
  end

  test "empty pending plan terminates successfully without a manifest" do
    send(self(), {:deployment_wait, "request-1", :empty})
    parent = self()

    assert 0 =
             Garden.DeploymentWait.observe("request-1", nil, 1000, fn kind, text ->
               send(parent, {kind, text})
             end)

    assert_received {:ok, "no pending deployments"}
    refute_received {:ok, "enqueued" <> _}
  end

  defp subscription do
    Subscription.cast!(%{name: "host", sid: "sub-1", seed_name: "host", seed_type: "nixos"})
  end

  defp deployment(request) do
    Deployment.cast!(%{
      sid: "dep-1",
      request_id: request,
      seed_deployments: [
        %{
          subscription_sid: "sub-1",
          seed: %{sid: "seed-a", name: "host", seed_type: "nixos", artifact: "/nix/store/a"}
        },
        %{
          subscription_sid: "sub-2",
          seed: %{
            sid: "seed-b",
            name: "user",
            seed_type: "home-manager",
            artifact: "/nix/store/b"
          }
        }
      ]
    })
  end
end
