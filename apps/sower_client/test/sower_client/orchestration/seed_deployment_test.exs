defmodule SowerClient.Orchestration.SeedDeploymentTest do
  use ExUnit.Case, async: true

  alias SowerClient.Orchestration.SeedDeployment

  test "casts valid seed deployment" do
    assert {:ok, %SeedDeployment{}} =
             SeedDeployment.cast(%{
               seed: %{
                 sid: "seed_123",
                 name: "my-seed",
                 seed_type: "nixos",
                 artifact: "/nix/store/abc"
               }
             })
  end
end
