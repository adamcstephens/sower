defmodule Nix.MixProject do
  use Mix.Project

  def project do
    [
      app: :nix,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "./config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cuid2_ex, "~> 0.2"},
      {:erlexec, "~> 2.0"},
      {:igniter, only: [:dev, :test]},
      {:jason, "~> 1.0"},
      {:typedstruct, "~> 0.5.4"},
      {:xema, "~> 0.17"}
    ]
  end
end
