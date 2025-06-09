defmodule SowerAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :sower_agent,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:deps_nix, "~> 2.0", only: [:dev]},
      {:slipstream, "~> 1.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end
end
