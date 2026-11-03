defmodule VMManager.LifetimeTest do
  use ExUnit.Case, async: true

  alias VMManager.Config

  test "both supported guest contracts can boot without an initial command" do
    config = %Config{
      id: "reusable-guest",
      kernel: "/kernel",
      initrd: "/initrd",
      guest: %Config.SowerGuest{},
      vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: nil}
    }

    options = Keyword.put(Config.to_options(config), :owner, self())
    assert :ok = VMManager.Execution.validate_options(options)

    assert :ok =
             VMManager.Execution.validate_options(
               Keyword.put(options, :config, %{config | guest: %Config.SowerGuest{contract: 1}})
             )
  end
end
