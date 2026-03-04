defmodule SowerAgent.ClientDeploymentTest do
  @moduledoc """
  Tests for deployment message handling and duplicate suppression.
  """
  use ExUnit.Case, async: false

  alias SowerAgent.Client

  # Mock socket for testing handle_message callbacks
  defmodule MockSocket do
    defstruct [:assigns, :active_deployments]

    def new(agent_sid \\ "test_agent_123") do
      %__MODULE__{
        assigns: %{agent_sid: agent_sid},
        active_deployments: %{}
      }
    end

    def with_active_deployment(socket, deployment) do
      put_in(socket.active_deployments[deployment.sid], deployment)
    end
  end

  describe "handle_message for deployment events" do
    test "enqueues deployment for new deployment_sid" do
      socket = MockSocket.new()

      deployment = %SowerClient.Orchestration.Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: false
      }

      payload = Map.from_struct(deployment)

      {:ok, updated_socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          payload,
          socket
        )

      # Verify deployment was added to active_deployments
      assert Map.has_key?(updated_socket.active_deployments, "deploy_123")
      assert updated_socket.active_deployments["deploy_123"].sid == "deploy_123"
    end

    test "ignores duplicate deployment events for already active deployment" do
      deployment = %SowerClient.Orchestration.Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: false
      }

      socket = MockSocket.new() |> MockSocket.with_active_deployment(deployment)

      payload = Map.from_struct(deployment)

      {:ok, updated_socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          payload,
          socket
        )

      # Verify active_deployments hasn't changed (no duplicate added)
      assert map_size(updated_socket.active_deployments) == 1
      assert Map.has_key?(updated_socket.active_deployments, "deploy_123")
      # Verify the deployment wasn't replaced (same reference would mean same object)
      assert updated_socket.active_deployments["deploy_123"] == deployment
    end

    test "allows simultaneous deployments for different sids" do
      socket = MockSocket.new()

      deployment1 = %SowerClient.Orchestration.Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: false
      }

      deployment2 = %SowerClient.Orchestration.Deployment{
        sid: "deploy_789",
        request_id: "dr_abc",
        seed_deployments: [],
        skipped: false
      }

      payload1 = Map.from_struct(deployment1)
      payload2 = Map.from_struct(deployment2)

      {:ok, socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          payload1,
          socket
        )

      {:ok, socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          payload2,
          socket
        )

      # Both deployments should be tracked
      assert map_size(socket.active_deployments) == 2
      assert Map.has_key?(socket.active_deployments, "deploy_123")
      assert Map.has_key?(socket.active_deployments, "deploy_789")
    end

    @tag :capture_log
    test "handles deployment:error event" do
      socket = MockSocket.new()

      payload = %{
        "request_id" => "dr_error_123",
        "reason" => "seeds_not_found"
      }

      {:ok, updated_socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment:error",
          payload,
          socket
        )

      # Socket should remain unchanged on error
      assert updated_socket.active_deployments == %{}
    end

    test "handles skipped deployment" do
      socket = MockSocket.new()

      deployment = %SowerClient.Orchestration.Deployment{
        sid: "deploy_existing",
        request_id: "dr_skip_456",
        seed_deployments: [],
        skipped: true
      }

      payload = Map.from_struct(deployment)

      {:ok, updated_socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          payload,
          socket
        )

      # Skipped deployments should not be added to active_deployments
      assert updated_socket.active_deployments == %{}
    end

    test "handles invalid deployment payload gracefully" do
      socket = MockSocket.new()

      payload = %{
        "invalid" => "data"
      }

      {:ok, _socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          payload,
          socket
        )

      # Should return {:ok, socket} even on error, not crash
      # The error is logged but not raised
    end

    test "duplicate suppression maintains separate state per deployment_sid" do
      socket = MockSocket.new()

      # First deployment - should be accepted
      deployment1 = %SowerClient.Orchestration.Deployment{
        sid: "deploy_first",
        request_id: "dr_1",
        seed_deployments: [],
        skipped: false
      }

      {:ok, socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          Map.from_struct(deployment1),
          socket
        )

      # Try to add duplicate of first - should be ignored
      {:ok, socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          Map.from_struct(deployment1),
          socket
        )

      # Second deployment (different sid) - should be accepted
      deployment2 = %SowerClient.Orchestration.Deployment{
        sid: "deploy_second",
        request_id: "dr_2",
        seed_deployments: [],
        skipped: false
      }

      {:ok, socket} =
        Client.handle_message(
          "agent:test_agent_123",
          "deployment",
          Map.from_struct(deployment2),
          socket
        )

      # Should have both deployments, but not the duplicate
      assert map_size(socket.active_deployments) == 2
      assert Map.has_key?(socket.active_deployments, "deploy_first")
      assert Map.has_key?(socket.active_deployments, "deploy_second")
    end
  end
end
