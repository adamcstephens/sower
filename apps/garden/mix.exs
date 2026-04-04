defmodule Garden.MixProject do
  use Mix.Project

  def project do
    [
      app: :garden,
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
      extra_applications: [:logger],
      mod: {Garden.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:quantum, "~> 3.0"},
      {:cuid2_ex, "~> 0.2"},
      {:jason, "~> 1.0"},
      {:jose, "~> 1.11"},
      {:nix, in_umbrella: true},
      {:slipstream, "~> 1.0"},
      # load typedstruct before typed_struct_ecto_changeset
      {:typedstruct, "~> 0.5", runtime: false},
      {:sower_client, in_umbrella: true},
      {:systemd,
       github: "hauleth/erlang-systemd", ref: "62723b2a99afca491cc5c8f15c7f72d108e84f4b"},
      {:zoneinfo, "~> 0.1.8"}
    ]
  end
end
