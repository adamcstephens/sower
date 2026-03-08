defmodule SowerCli.Seed.SubmitTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "command parsing" do
    test "parses required options" do
      config = SowerCli.config()

      {:ok, [:seed, :submit], parsed} =
        Optimus.parse(config, [
          "seed",
          "submit",
          "-t",
          "nixos",
          "-n",
          "myhost",
          "-a",
          "/nix/store/abc123-nixos-system-myhost-25.05"
        ])

      assert parsed.options.type == "nixos"
      assert parsed.options.name == "myhost"
      assert parsed.options.artifact == "/nix/store/abc123-nixos-system-myhost-25.05"
    end

    test "parses multiple tags" do
      config = SowerCli.config()

      {:ok, [:seed, :submit], parsed} =
        Optimus.parse(config, [
          "seed",
          "submit",
          "-t",
          "nixos",
          "-n",
          "myhost",
          "-a",
          "/nix/store/abc123-nixos",
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
        {:ok, [:seed, :submit], parsed} =
          Optimus.parse(config, [
            "seed",
            "submit",
            "-t",
            seed_type,
            "-n",
            "test",
            "-a",
            "/nix/store/abc123"
          ])

        assert parsed.options.type == seed_type
      end
    end

    test "rejects invalid seed type" do
      config = SowerCli.config()

      result =
        Optimus.parse(config, [
          "seed",
          "submit",
          "-t",
          "invalid",
          "-n",
          "test",
          "-a",
          "/nix/store/abc123"
        ])

      assert {:error, [:seed, :submit], _} = result
    end

    test "requires --type option" do
      config = SowerCli.config()

      result =
        Optimus.parse(config, [
          "seed",
          "submit",
          "-n",
          "myhost",
          "-a",
          "/nix/store/abc123"
        ])

      assert {:error, [:seed, :submit], _} = result
    end

    test "requires --name option" do
      config = SowerCli.config()

      result =
        Optimus.parse(config, [
          "seed",
          "submit",
          "-t",
          "nixos",
          "-a",
          "/nix/store/abc123"
        ])

      assert {:error, [:seed, :submit], _} = result
    end

    test "requires --artifact option" do
      config = SowerCli.config()

      result = Optimus.parse(config, ["seed", "submit", "-t", "nixos", "-n", "myhost"])

      assert {:error, [:seed, :submit], _} = result
    end

    test "parses debug flag" do
      config = SowerCli.config()

      {:ok, [:seed, :submit], parsed} =
        Optimus.parse(config, [
          "seed",
          "submit",
          "-t",
          "nixos",
          "-n",
          "myhost",
          "-a",
          "/nix/store/abc123",
          "-d"
        ])

      assert parsed.flags.debug == true
    end
  end

  describe "run/2" do
    test "returns error when server config is missing" do
      Application.put_env(:sower_cli, :config, %SowerClient.Config{
        endpoint: nil,
        access_token: nil
      })

      output =
        capture_io(fn ->
          result =
            SowerCli.Seed.Submit.run(%{debug: false}, %{
              name: "test",
              type: "nixos",
              artifact: "/nix/store/abc123",
              tag: []
            })

          assert {:error, :missing_server_config} = result
        end)

      assert output =~ "endpoint is required" or output =~ "access_token is required"
    end
  end
end
