defmodule CloudHypervisor.MixProject do
  use Mix.Project

  def project do
    [
      app: :cloud_hypervisor,
      version: "0.1.6",
      build_path: "../../_build",
      config_path: "./config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jason, "~> 1.0"},
      {:req, "~> 0.6"},
      {:rexec, git: "https://github.com/adamcstephens/rexec.git", branch: "main"},
      {:typedstruct, "0.5.4",
       git: "https://github.com/saleyn/typedstruct.git",
       ref: "343c6435a7ef06dd2662e950d33cb957f81bf68d",
       runtime: false}
    ]
  end
end
