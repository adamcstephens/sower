defmodule SowerClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :sower_client,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps: deps(),
      deps_path: "../../deps",
      elixir: "~> 1.18",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      version: String.trim(File.read!(Path.expand("../../VERSION", __DIR__)))
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
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:jason, "~> 1.0"},
      # load typedstruct before typed_struct_ecto_changeset
      {:open_api_spex, "~> 3.20"},
      {:typedstruct, "~> 0.5", runtime: false},
      {:typed_struct_ecto_changeset, "~> 1.1", override: true},
      {:typed_struct_ctor, "~> 0.1"}
    ]
  end
end
