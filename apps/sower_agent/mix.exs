defmodule SowerAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :sower_agent,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps: deps(),
      deps_path: "../../deps",
      elixir: "~> 1.18",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      version: SowerUmbrella.MixProject.project()[:version]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SowerAgent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exsync, "~> 0.4", only: [:dev]},
      {:cuid2_ex, "~> 0.2"},
      {:deps_nix, "~> 2.0", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:jason, "~> 1.0"},
      {:slipstream, "~> 1.0"},
      # load typedstruct before typed_struct_ecto_changeset
      {:typedstruct, "~> 0.5"},
      {:sower_client, in_umbrella: true}
    ]
  end
end
