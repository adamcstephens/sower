defmodule IncusClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :incus_client,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {IncusClient.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:jason, "~> 1.0"},
      {:open_api_spex,
       git: "https://github.com/adamcstephens/open_api_spex.git",
       ref: "d7ad0631b5689666d29115f27c21c5d397242888"},
      {:req, "~> 0.5"},
      {:typedstruct, "~> 0.5"}
    ]
  end
end
