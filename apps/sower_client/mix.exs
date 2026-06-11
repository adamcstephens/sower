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
      elixirc_options: [warnings_as_errors: Mix.env() == :prod],
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
      {:ecto, "~> 3.0"},
      {:cuid2_ex, "~> 0.2"},
      {:jason, "~> 1.0"},
      {:open_api_spex, "~> 3.22"},
      {:req, "~> 0.6"},
      {:slipstream, "~> 1.0"},
      {:typedstruct, "~> 0.5", runtime: false}
    ]
  end
end
