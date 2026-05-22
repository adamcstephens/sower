defmodule SowerUmbrella.MixProject do
  use Mix.Project

  def project do
    version = String.trim(File.read!(Path.expand("VERSION", __DIR__)))

    [
      apps_path: "apps",
      deps: deps(),
      releases: [
        garden: [
          version: version,
          applications: [garden: :permanent],
          runtime_config_path: "config/runtime_garden.exs",
          include_executables_for: [:unix]
        ],
        cli: [
          version: version,
          applications: [sower_cli: :permanent],
          config_path: "./apps/sower_cli/config/config.exs",
          runtime_config_path: "./apps/sower_cli/config/runtime.exs",
          include_executables_for: [:unix],
          steps: [:assemble]
        ],
        server: [
          version: version,
          applications: [sower: :permanent],
          runtime_config_path: "config/runtime_server.exs",
          include_executables_for: [:unix]
        ]
      ],
      start_permanent: Mix.env() == :prod,
      version: version,
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:mix_audit, "~> 2.0", only: [:test, :dev]},
      {:dialyxir, "~> 1.0", only: [:dev]},
      {:deps_nix, "~> 3.0", only: [:dev]},
      {:igniter, "~> 0.7", only: [:dev, :test], override: true}
    ]
  end
end
