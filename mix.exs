defmodule SowerUmbrella.MixProject do
  use Mix.Project

  def project do
    version = String.trim(File.read!(Path.join(Path.dirname(__ENV__.file), "VERSION")))

    [
      apps_path: "apps",
      deps: deps(),
      releases: [
        agent: [
          version: version,
          applications: [sower_agent: :permanent],
          runtime_config_path: "config/runtime_agent.exs"
        ],
        server: [
          version: version,
          applications: [sower: :permanent],
          runtime_config_path: "config/runtime.exs"
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
      {:deps_nix, "~> 2.0", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end
end
