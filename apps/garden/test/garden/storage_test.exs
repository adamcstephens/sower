defmodule Garden.StorageTest do
  use ExUnit.Case, async: true

  alias Garden.Storage

  describe "check_attempt/2" do
    test "allows the first attempt then blocks within the cooldown window" do
      key = {:reregistration, :cooldown_case}

      assert :ok = Storage.check_attempt(key)
      assert {:cooldown, _elapsed} = Storage.check_attempt(key)
    end

    test "stops allowing attempts once the cap is reached" do
      key = {:reregistration, :cap_case}
      opts = [cooldown_seconds: 0, max_attempts: 2]

      assert :ok = Storage.check_attempt(key, opts)
      assert :ok = Storage.check_attempt(key, opts)
      assert :exhausted = Storage.check_attempt(key, opts)
      assert :exhausted = Storage.check_attempt(key, opts)
    end

    test "keys are independent" do
      opts = [cooldown_seconds: 0, max_attempts: 1]

      assert :ok = Storage.check_attempt({:reregistration, :a}, opts)
      assert :ok = Storage.check_attempt({:reregistration, :b}, opts)
      assert :exhausted = Storage.check_attempt({:reregistration, :a}, opts)
    end
  end
end
