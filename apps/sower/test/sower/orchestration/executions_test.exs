defmodule Sower.Orchestration.ExecutionsTest do
  use ExUnit.Case, async: true

  alias Sower.Orchestration.Executions

  test "placement filters authority, contract, system, network and every resource before random choice" do
    request = %{
      "system" => "x86_64-linux",
      "network" => "full",
      "cpus" => 2,
      "memory" => 4096,
      "scratch_bytes" => 8192
    }

    capability = %{
      "enabled" => true,
      "systems" => ["x86_64-linux"],
      "contract_min" => 1,
      "contract_max" => 1,
      "networks" => ["none", "full"],
      "available" => %{"vms" => 1, "cpus" => 2, "memory" => 4096, "scratch_bytes" => 8192}
    }

    assert Executions.compatible?(request, capability)
    refute Executions.compatible?(request, %{capability | "enabled" => false})
    refute Executions.compatible?(request, %{capability | "systems" => ["aarch64-linux"]})
    refute Executions.compatible?(request, %{capability | "contract_min" => 2})
    refute Executions.compatible?(request, %{capability | "contract_max" => 0})
    refute Executions.compatible?(request, %{capability | "networks" => ["none"]})

    for dimension <- ["vms", "cpus", "memory", "scratch_bytes"] do
      refute Executions.compatible?(request, put_in(capability, ["available", dimension], 0))
    end

    assert Executions.choose([:first, :second], &hd/1) == :first
    assert Executions.choose([:first, :second], &List.last/1) == :second
    assert Executions.choose([], &hd/1) == nil
  end
end
