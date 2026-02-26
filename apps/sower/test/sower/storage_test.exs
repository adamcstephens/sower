defmodule Sower.StorageTest do
  use Sower.DataCase

  alias Sower.Orchestration
  alias Sower.Storage
  alias SowerClient.Storage.DeploymentLogUploadRequest
  alias SowerClient.Storage.PresignedUploadReply

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  describe "presign_deployment_log_upload/2" do
    setup %{organization: org} do
      agent = agent_fixture(%{org_id: org.org_id})
      other_agent = agent_fixture(%{org_id: org.org_id, name: "other agent"})

      seed = seed_fixture(%{org_id: org.org_id})

      deployment =
        deployment_fixture(%{
          org_id: org.org_id,
          agent_id: agent.id,
          seeds: [seed],
          subscriptions: []
        })

      deployment = Sower.Repo.preload(deployment, :seeds)

      %{agent: agent, other_agent: other_agent, deployment: deployment, seed: seed}
    end

    test "returns presigned upload URL for valid request", %{
      agent: agent,
      deployment: deployment,
      seed: seed
    } do
      request = %DeploymentLogUploadRequest{
        deployment_sid: deployment.sid,
        seed_sid: seed.sid,
        checksum_sha256: nil
      }

      # Mock the presign_upload function to avoid S3 dependency
      mock_presign = fn path, _opts ->
        {:ok, "https://mock-s3.example.com/#{path}?signed=true"}
      end

      assert {:ok, %PresignedUploadReply{} = reply} =
               Storage.presign_deployment_log_upload(agent, request, mock_presign)

      assert reply.url ==
               "https://mock-s3.example.com/logs/deployments/#{deployment.sid}/seeds/#{seed.sid}.log?signed=true"

      assert reply.method == "PUT"
      assert reply.headers == %{}
    end

    test "returns error for non-existent deployment", %{agent: agent} do
      request = %DeploymentLogUploadRequest{
        deployment_sid: "nonexistent_deploy",
        seed_sid: "some_seed",
        checksum_sha256: nil
      }

      assert {:error, :unauthorized} =
               Storage.presign_deployment_log_upload(agent, request)
    end

    test "returns unauthorized error for deployment owned by different agent", %{
      other_agent: other_agent,
      deployment: deployment,
      seed: seed
    } do
      request = %DeploymentLogUploadRequest{
        deployment_sid: deployment.sid,
        seed_sid: seed.sid,
        checksum_sha256: nil
      }

      assert {:error, :unauthorized} =
               Storage.presign_deployment_log_upload(other_agent, request)
    end

    test "returns error when seed is not associated with deployment", %{
      agent: agent,
      deployment: deployment
    } do
      other_seed = seed_fixture(%{org_id: agent.org_id, name: "other_seed"})

      request = %DeploymentLogUploadRequest{
        deployment_sid: deployment.sid,
        seed_sid: other_seed.sid,
        checksum_sha256: nil
      }

      assert {:error, :seed_not_in_deployment} =
               Storage.presign_deployment_log_upload(agent, request)
    end
  end
end
