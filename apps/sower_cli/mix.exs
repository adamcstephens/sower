defmodule SowerCli.MixProject do
  use Mix.Project

  def project do
    [
      aliases: aliases(),
      app: :sower_cli,
      build_path: "../../_build",
      config_path: "./config/config.exs",
      deps: deps(),
      deps_path: "../../deps",
      elixir: "~> 1.19",
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

  defp aliases() do
    [
      cli: ["run ./cli.exs"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:optimus, "~> 0.5"}
    ]
  end
end
