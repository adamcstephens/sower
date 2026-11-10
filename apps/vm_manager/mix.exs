defmodule VMManager.MixProject do
  use Mix.Project

  def project do
    [
      app: :vm_manager,
      version: String.trim(File.read!(Path.expand("../../VERSION", __DIR__))),
      build_path: "../../_build",
      config_path: "./config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:cloud_hypervisor, in_umbrella: true},
        {:rexec, git: "https://github.com/adamcstephens/rexec.git", branch: "main"},
        {:jason, "~> 1.0"},
        {:typedstruct, "0.5.4",
         git: "https://github.com/saleyn/typedstruct.git",
         ref: "343c6435a7ef06dd2662e950d33cb957f81bf68d",
         runtime: false,
         override: true}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto], mod: {VMManager.Application, []}]
end
