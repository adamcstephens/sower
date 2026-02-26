defmodule SowerClient.Orchestration.SeedDeploymentTest do
  use ExUnit.Case, async: true

  alias SowerClient.Orchestration.SeedDeployment

  test "log_path/2 builds deterministic seed deployment log path" do
    assert SeedDeployment.log_path("deploy_123", "seed_456") ==
             "logs/deployments/deploy_123/seeds/seed_456.log"
  end
end
