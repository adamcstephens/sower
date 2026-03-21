defmodule SowerClient.Storage.DeploymentLogUploadTest do
  use ExUnit.Case, async: true

  alias SowerClient.Storage.DeploymentLogUploadRequest
  alias SowerClient.Storage.PresignedUploadReply

  describe "DeploymentLogUploadRequest" do
    test "cast/1 with valid data succeeds" do
      assert {:ok, request} =
               DeploymentLogUploadRequest.cast(%{
                 "deployment_sid" => "deploy_123",
                 "seed_sid" => "seed_456",
                 "checksum_sha256" => "abc123"
               })

      assert request.deployment_sid == "deploy_123"
      assert request.seed_sid == "seed_456"
      assert request.checksum_sha256 == "abc123"
    end

    test "cast/1 without checksum succeeds" do
      assert {:ok, request} =
               DeploymentLogUploadRequest.cast(%{
                 "deployment_sid" => "deploy_123",
                 "seed_sid" => "seed_456"
               })

      assert request.deployment_sid == "deploy_123"
      assert request.seed_sid == "seed_456"
      assert request.checksum_sha256 == nil
    end

    test "cast/1 with missing deployment_sid fails" do
      assert {:error, _} =
               DeploymentLogUploadRequest.cast(%{
                 "seed_sid" => "seed_456"
               })
    end

    test "cast/1 with missing seed_sid fails" do
      assert {:error, _} =
               DeploymentLogUploadRequest.cast(%{
                 "deployment_sid" => "deploy_123"
               })
    end

    test "event/0 returns correct channel event" do
      assert DeploymentLogUploadRequest.event() == "storage:deployment_log_upload"
    end
  end

  describe "PresignedUploadReply" do
    test "cast/1 with valid data succeeds" do
      assert {:ok, reply} =
               PresignedUploadReply.cast(%{
                 "url" => "https://s3.example.com/upload",
                 "method" => "PUT",
                 "headers" => %{"x-amz-checksum-sha256" => "abc123"}
               })

      assert reply.url == "https://s3.example.com/upload"
      assert reply.method == "PUT"
      assert reply.headers == %{"x-amz-checksum-sha256" => "abc123"}
    end

    test "cast!/1 with valid data returns struct" do
      reply =
        PresignedUploadReply.cast!(%{
          "url" => "https://s3.example.com/upload",
          "method" => "PUT",
          "headers" => %{}
        })

      assert reply.url == "https://s3.example.com/upload"
      assert reply.method == "PUT"
      assert reply.headers == %{}
    end

    test "cast/1 with missing required gardens fails" do
      assert {:error, _} =
               PresignedUploadReply.cast(%{
                 "method" => "PUT",
                 "headers" => %{}
               })
    end
  end
end
