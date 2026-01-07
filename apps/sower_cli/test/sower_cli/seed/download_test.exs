defmodule SowerCli.Seed.DownloadTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "command parsing" do
    test "parses required options" do
      config = SowerCli.config()

      {:ok, [:seed, :download], parsed} =
        Optimus.parse(config, ["seed", "download", "-t", "nixos", "-n", "myhost"])

      assert parsed.options.type == "nixos"
      assert parsed.options.name == "myhost"
    end

    test "parses multiple tags" do
      config = SowerCli.config()

      {:ok, [:seed, :download], parsed} =
        Optimus.parse(config, [
          "seed",
          "download",
          "-t",
          "nixos",
          "-n",
          "myhost",
          "-T",
          "env=prod",
          "-T",
          "branch=main"
        ])

      assert parsed.options.tag == ["env=prod", "branch=main"]
    end

    test "accepts all valid seed types" do
      config = SowerCli.config()

      for seed_type <- ["nixos", "home-manager", "nix-darwin", "service"] do
        {:ok, [:seed, :download], parsed} =
          Optimus.parse(config, ["seed", "download", "-t", seed_type, "-n", "test"])

        assert parsed.options.type == seed_type
      end
    end

    test "rejects invalid seed type" do
      config = SowerCli.config()

      result = Optimus.parse(config, ["seed", "download", "-t", "invalid", "-n", "test"])

      assert {:error, [:seed, :download], _} = result
    end

    test "requires --type option" do
      config = SowerCli.config()

      result = Optimus.parse(config, ["seed", "download", "-n", "myhost"])

      assert {:error, [:seed, :download], _} = result
    end

    test "requires --name option" do
      config = SowerCli.config()

      result = Optimus.parse(config, ["seed", "download", "-t", "nixos"])

      assert {:error, [:seed, :download], _} = result
    end

    test "parses debug flag" do
      config = SowerCli.config()

      {:ok, [:seed, :download], parsed} =
        Optimus.parse(config, ["seed", "download", "-t", "nixos", "-n", "myhost", "-d"])

      assert parsed.flags.debug == true
    end
  end

  describe "run/2" do
    test "returns error when server config is missing" do
      # Set config with missing endpoint and access_token
      Application.put_env(:sower_cli, :config, %SowerClient.Config{
        endpoint: nil,
        access_token: nil
      })

      output =
        capture_io(fn ->
          result =
            SowerCli.Seed.Download.run(%{debug: false}, %{name: "test", type: "nixos", tag: []})

          assert {:error, :missing_server_config} = result
        end)

      assert output =~ "endpoint is required" or output =~ "access_token is required"
    end
  end
end
