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
      version: SowerUmbrella.MixProject.project()[:version]
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
      {:argon2, "~> 1.2"},
      {:bandit, "~> 1.0"},
      {:cloak_ecto, "~> 1.3.0"},
      {:cuid2_ex, "~> 0.2.0"},
      {:deps_nix, "~> 2.0", only: [:dev]},
      {:ecto_sql, "~> 3.11"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:ex_json_schema, "~> 0.11.1"},
      {:faker, "~> 0.18", only: :test},
      {:finch, "~> 0.13"},
      {:floki, ">= 0.30.0", only: :test},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      {:joken, "~> 2.6.1"},
      {:libcluster_consul, "~> 1.3"},
      {:mime, "~> 2.0.6"},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:open_api_spex, "~> 3.20"},
      {:permit, "~> 0.3.0"},
      {:permit_ecto, "~> 0.2.3"},
      {:phoenix, "~> 1.7.7"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0.0"},
      {:postgrex, ">= 0.0.0"},
      {:req, ">= 0.5.8"},
      {:shortuuid, "~> 4.0"},
      # load typedstruct before typed_struct_ecto_changeset
      {:typedstruct, "~> 0.5"},
      {:sower_client, in_umbrella: true},
      {:systemd, "~> 0.6"},
      {:tailwind, "~> 0.3.0", runtime: Mix.env() == :dev},
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
