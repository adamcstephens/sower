defmodule SowerUmbrella.MixProject do
  use Mix.Project

  def project do
    version = String.trim(File.read!(Path.expand("VERSION", __DIR__)))

    [
      apps_path: "apps",
      deps: deps(),
      releases: [
        agent: [
          version: version,
          applications: [sower_agent: :permanent],
          runtime_config_path: "config/runtime_agent.exs",
          include_executables_for: [:unix]
        ],
        server: [
          version: version,
          applications: [sower: :permanent],
          runtime_config_path: "config/runtime_server.exs",
          include_executables_for: [:unix]
        ]
      ],
      start_permanent: Mix.env() == :prod,
      version: version
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:dialyxir, "~> 1.0", only: [:dev]},
      {:deps_nix, "~> 2.0", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end
end
