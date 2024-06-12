defmodule Sower.MixProject do
  use Mix.Project

  def project do
    [
      aliases: aliases(),
      app: :sower,
      deps: deps(),
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      version: String.trim(File.read!("VERSION"))
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0.0"},
      {:ash_authentication, "~> 4.0.0"},
      {:ash_authentication_phoenix, "~> 2.0.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_phoenix, "~> 2.0.0"},
      {:ash_postgres, "~> 2.0.0"},
      {:bandit, "~> 1.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:ex_json_schema, "~> 0.10.2"},
      {:finch, "~> 0.13"},
      {:floki, ">= 0.30.0", only: :test},
      {:gettext, "~> 0.20"},
      {:hackney, "~> 1.8"},
      {:jason, "~> 1.2"},
      {:joken, "~> 2.6.1"},
      {:makeup, "~> 1.1"},
      {:makeup_json, "~> 0.1.0"},
      {:open_api_spex, "~> 3.19"},
      {:phoenix, "~> 1.7.7"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 4.1.1"},
      {:phoenix_live_dashboard, "~> 0.8.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 0.20.0"},
      {:postgrex, ">= 0.0.0"},
      {:redoc_ui_plug, "~> 0.2.1"},
      {:sentry, "~> 10.5"},
      {:swoosh, "~> 1.3"},
      {:systemd, "~> 0.6"},
      {:tailwind, "~> 0.2.0", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0.0"},
      {:telemetry_poller, "~> 1.1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind default", "esbuild default"],
      "assets.deploy": ["tailwind default --minify", "esbuild default --minify", "phx.digest"]
    ]
  end

  def application do
    [
      mod: {Sower.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
