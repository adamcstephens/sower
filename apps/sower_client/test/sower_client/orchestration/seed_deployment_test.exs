defmodule SowerClient.Orchestration.SeedDeploymentTest do
  use ExUnit.Case, async: true

  alias SowerClient.Orchestration.SeedDeployment

  test "legacy deployment payloads do not authorize policy overrides" do
    assert {:ok, deployment} = SeedDeployment.cast(%{"action" => "restart"})
    refute deployment.override
  end

  test "authorized override survives the deployment wire round trip" do
    deployment = %SeedDeployment{
      seed: %SowerClient.Seed{name: "host", seed_type: "nixos", artifact: "/nix/store/system"},
      action: "restart",
      override: true
    }

    assert {:ok, decoded} =
             deployment |> Jason.encode!() |> Jason.decode!() |> SeedDeployment.cast()

    assert decoded.override
    assert decoded.action == "restart"
  end
end
