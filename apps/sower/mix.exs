defmodule Sower.MixProject do
  use Mix.Project

  def project do
    [
      aliases: aliases(),
      app: :sower,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps: deps(),
      deps_path: "../../deps",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      version: String.trim(File.read!(Path.expand("../../VERSION", __DIR__)))
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Sower.Application, []}
    ]
  end

  defp deps do
    [
      {:argon2id_elixir, "~> 1.1"},
      {:bandit, "~> 1.0"},
      {:cloak_ecto, "~> 1.3.0"},
      {:cuid2_ex, "~> 0.2.0"},
      {:ecto_sql, "~> 3.11"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:open_api_spex, "~> 3.22"},
      {:faker, "~> 0.18", only: :test},
      {:finch, "~> 0.13"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:joken, "~> 2.6.1"},
      {:libcluster_consul, "~> 1.3"},
      {:mime, "~> 2.0.6"},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:nix, in_umbrella: true},
      {:permit, "~> 0.3.0"},
      {:permit_ecto, "~> 0.2.3"},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:postgrex, ">= 0.0.0"},
      {:req, ">= 0.5.8"},
      {:shortuuid, "~> 4.0"},
      {:sower_client, in_umbrella: true},
      {:systemd,
       github: "hauleth/erlang-systemd", ref: "62723b2a99afca491cc5c8f15c7f72d108e84f4b"},
      {:tailwind, "~> 0.4.0", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_oidcc, "~> 0.3"},
      {:uuidv7, "~> 1.0.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run apps/sower/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "tailwind sower",
        "esbuild sower"
      ],
      "assets.deploy": [
        "tailwind sower --minify",
        "esbuild sower --minify",
        "phx.digest"
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
