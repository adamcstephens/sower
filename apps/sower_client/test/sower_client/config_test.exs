defmodule SowerClient.ConfigTest do
  use ExUnit.Case, async: true

  alias SowerClient.Config
  alias SowerClient.Orchestration.DeploymentProfile

  describe "xdg_config_path/2" do
    test "respects XDG_CONFIG_HOME when set and file exists" do
      tmp_dir = System.tmp_dir!()
      config_home = Path.join(tmp_dir, "xdg_config_#{:rand.uniform(1000)}")
      config_file = Path.join([config_home, "sower", "client.json"])

      # Create the config file so the fallback to /etc doesn't trigger
      File.mkdir_p!(Path.dirname(config_file))
      File.write!(config_file, "{}")

      with_env(%{"XDG_CONFIG_HOME" => config_home}, fn ->
        result = Config.xdg_config_path("sower", "client.json")
        assert result == config_file
      end)

      File.rm_rf!(config_home)
    end

    test "falls back to system config when user config file does not exist" do
      tmp_dir = System.tmp_dir!()
      config_home = Path.join(tmp_dir, "empty_config_#{:rand.uniform(1000)}")
      File.mkdir_p!(config_home)

      with_env(
        %{
          "XDG_CONFIG_HOME" => config_home,
          "USER" => "testuser"
        },
        fn ->
          result = Config.xdg_config_path("sower", "client.json")
          assert result == "/etc/sower/client.json"
        end
      )

      File.rm_rf!(config_home)
    end

    test "returns system config path for root user regardless of file existence" do
      tmp_dir = System.tmp_dir!()
      config_home = Path.join(tmp_dir, "root_config_#{:rand.uniform(1000)}")
      config_file = Path.join([config_home, "sower", "client.json"])

      # Create a config file (root ignores it anyway)
      File.mkdir_p!(Path.dirname(config_file))
      File.write!(config_file, "{}")

      with_env(
        %{
          "XDG_CONFIG_HOME" => config_home,
          "USER" => "root"
        },
        fn ->
          result = Config.xdg_config_path("sower", "client.json")
          assert result == "/etc/sower/client.json"
        end
      )

      File.rm_rf!(config_home)
    end
  end

  describe "xdg_state_path/1" do
    test "respects XDG_STATE_HOME when set" do
      with_env(%{"XDG_STATE_HOME" => "/custom/state"}, fn ->
        result = Config.xdg_state_path("sower_agent")
        assert result =~ "/custom/state/sower_agent"
      end)
    end
  end

  describe "parse_file_values/1" do
    setup do
      tmp_dir = System.tmp_dir!()
      token_file = Path.join(tmp_dir, "test_token_#{:rand.uniform(1000)}")
      File.write!(token_file, "secret-token-123\n")

      on_exit(fn -> File.rm(token_file) end)

      %{token_file: token_file}
    end

    test "expands _file suffix and reads file content", %{token_file: token_file} do
      config = %{"access_token_file" => token_file, "endpoint" => "https://example.com"}

      result = Config.parse_file_values(config)

      assert result["access_token"] == "secret-token-123"
      assert result["endpoint"] == "https://example.com"
      refute Map.has_key?(result, "access_token_file")
    end

    test "handles atom keys", %{token_file: token_file} do
      config = %{access_token_file: token_file, endpoint: "https://example.com"}

      result = Config.parse_file_values(config)

      assert result["access_token"] == "secret-token-123"
      assert result["endpoint"] == "https://example.com"
    end

    test "leaves non-file keys unchanged" do
      config = %{"endpoint" => "https://example.com", "name" => "myhost"}

      result = Config.parse_file_values(config)

      assert result == config
    end

    test "prefers direct values over _file values without reading files" do
      config = %{
        "access_token" => "token-from-env",
        "access_token_file" => "/nonexistent/access_token"
      }

      result = Config.parse_file_values(config)

      assert result["access_token"] == "token-from-env"
      refute Map.has_key?(result, "access_token_file")
    end
  end

  describe "read_config_file/1" do
    setup do
      tmp_dir = System.tmp_dir!()
      config_file = Path.join(tmp_dir, "test_config_#{:rand.uniform(1000)}.json")

      config_data = %{
        "endpoint" => "https://my.sower.dev",
        "cache" => "attic://server:cache"
      }

      File.write!(config_file, Jason.encode!(config_data))

      on_exit(fn -> File.rm(config_file) end)

      %{config_file: config_file, config_data: config_data}
    end

    test "reads and parses JSON config file", %{
      config_file: config_file,
      config_data: config_data
    } do
      result = Config.read_config_file(config_file)
      assert result == config_data
    end

    test "returns empty map when file doesn't exist" do
      result = Config.read_config_file("/nonexistent/path.json")
      assert result == %{}
    end
  end

  describe "load/2" do
    setup do
      tmp_dir = System.tmp_dir!()
      config_file = Path.join(tmp_dir, "test_config_#{:rand.uniform(1000)}.json")

      config_data = %{
        "endpoint" => "https://my.sower.dev",
        "caches" => ["attic://server:cache"],
        "name" => "testhost"
      }

      File.write!(config_file, Jason.encode!(config_data))

      on_exit(fn -> File.rm(config_file) end)

      %{config_file: config_file}
    end

    test "loads config with defaults and overrides", %{config_file: config_file} do
      config =
        Config.load(
          overrides: %{"name" => "override-host"},
          config_path: config_file,
          defaults: %{"state_directory" => "/var/lib/test"}
        )

      assert %Config{} = config
      assert config.endpoint == "https://my.sower.dev"
      assert config.caches == ["attic://server:cache"]
      assert config.name == "override-host"
      assert config.state_directory == "/var/lib/test"
    end

    test "returns struct when no config file exists" do
      config =
        Config.load(
          config_path: "/nonexistent/path.json",
          defaults: %{"endpoint" => "https://default.com"}
        )

      assert %Config{} = config
      assert config.endpoint == "https://default.com"
    end

    test "casts deployment_profiles additionalProperties into deployment profiles", %{
      config_file: config_file
    } do
      config_data = %{
        "endpoint" => "https://my.sower.dev",
        "deployment_profiles" => %{
          "default" => %{"reboot_policy" => "when-required"}
        }
      }

      File.write!(config_file, Jason.encode!(config_data))

      config = Config.load(config_path: config_file)

      assert %Config{} = config
      assert %DeploymentProfile{} = config.deployment_profiles["default"]
      assert config.deployment_profiles["default"].reboot_policy == "when-required"
      assert config.deployment_profiles["default"].activation_args == []
    end

    test "prefers access_token override over access_token_file from config", %{
      config_file: config_file
    } do
      config_data = %{
        "access_token_file" => "/nonexistent/access_token"
      }

      File.write!(config_file, Jason.encode!(config_data))

      config =
        Config.load(config_path: config_file, overrides: %{"access_token" => "token-from-env"})

      assert %Config{} = config
      assert config.access_token == "token-from-env"
    end
  end

  # Helper to temporarily set environment variables
  defp with_env(env_vars, fun) do
    original_env =
      Enum.map(env_vars, fn {key, _value} ->
        {key, System.get_env(key)}
      end)
      |> Map.new()

    try do
      Enum.each(env_vars, fn {key, value} ->
        System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(original_env, fn {key, value} ->
        if value do
          System.put_env(key, value)
        else
          System.delete_env(key)
        end
      end)
    end
  end
end
