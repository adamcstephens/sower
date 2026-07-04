defmodule SowerCliTest do
  use ExUnit.Case

  test "build interface matches the fixture shared with the Rust CLI" do
    fixture =
      Path.expand("../priv/build_interface.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    build = Enum.find(SowerCli.config().subcommands, &(&1.name == "build"))

    assert long_names(build.flags) == fixture["flags"]
    assert long_names(build.options) == fixture["options"]
  end

  defp long_names(flags_or_options) do
    flags_or_options
    |> Enum.map(fn %{long: long} -> String.trim_leading(long, "-") end)
    |> Enum.sort()
  end
end
