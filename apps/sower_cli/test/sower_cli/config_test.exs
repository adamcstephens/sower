defmodule SowerCli.ConfigTest do
  use ExUnit.Case, async: true

  describe "load/1" do
    test "loads config and stores in application env" do
      config =
        SowerCli.Config.load(
          overrides: %{"endpoint" => "https://test.com", "access_token_file" => nil}
        )

      assert %SowerClient.Config{} = config
      assert config.endpoint == "https://test.com"

      # Verify it's stored in app env
      assert SowerCli.Config.get() == config
    end
  end

  describe "get/0" do
    test "returns cached config from application env" do
      config =
        SowerCli.Config.load(
          overrides: %{"caches" => ["attic://server:cache"], "access_token_file" => nil}
        )

      cached = SowerCli.Config.get()

      assert cached == config
      assert cached.caches == ["attic://server:cache"]
    end
  end

  describe "require_server_connection/1" do
    test "returns error when endpoint is missing" do
      config = %SowerClient.Config{access_token: "token123"}

      assert {:error, ["endpoint is required (set via config file or --endpoint option)"]} =
               SowerCli.Config.require_server_connection(config)
    end

    test "returns error when access_token is missing" do
      config = %SowerClient.Config{endpoint: "https://test.com"}

      assert {:error, ["access_token is required (set via config file or access_token_file)"]} =
               SowerCli.Config.require_server_connection(config)
    end

    test "returns :ok when both are present" do
      config = %SowerClient.Config{
        endpoint: "https://test.com",
        access_token: "token123"
      }

      assert :ok = SowerCli.Config.require_server_connection(config)
    end
  end
end
