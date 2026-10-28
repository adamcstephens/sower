defmodule Garden.VM.LifetimeTest do
  use ExUnit.Case, async: true
  alias Garden.{Image, VM}

  test "persistent boot requires a reusable guest contract, not a command" do
    image = %Image{
      directory: "/unused",
      kernel: "/kernel",
      initrd: "/initrd",
      root: "/root",
      cmdline: "",
      contract: 2
    }

    assert :ok = VM.Execution.validate_options(image: image, owner: self())

    assert {:error, :persistent_guest_contract_required} =
             VM.Execution.validate_options(image: %{image | contract: 1}, owner: self())

    assert :ok =
             VM.Execution.validate_options(
               image: %{image | contract: 1},
               owner: self(),
               command: %VM.Command{path: "/bin/true"}
             )
  end
end
