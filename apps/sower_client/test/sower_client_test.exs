defmodule SowerClientTest do
  use ExUnit.Case
  doctest SowerClient

  test "pending deployments require both the seed identity and its web link" do
    alias SowerClient.Orchestration.PendingDeployment

    payload = %{
      "seed_sid" => "seed_123",
      "seed_url" => "https://sower.example/seeds/seed_123"
    }

    assert {:ok, pending} = PendingDeployment.cast(payload)
    assert Jason.decode!(Jason.encode!(pending)) == payload

    for field <- ["seed_sid", "seed_url"] do
      assert {:error, _} = PendingDeployment.cast(Map.delete(payload, field))
    end
  end
end
