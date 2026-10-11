defmodule GardenTest do
  use ExUnit.Case

  test "loads a local garden without server credentials" do
    previous = Garden.Config.get()

    on_exit(fn -> Application.put_env(:garden, :config, previous) end)

    config = Garden.Config.load(%{}, skip_config_file: true)
    assert config.endpoint == nil
    assert config.access_token == nil
  end
end
