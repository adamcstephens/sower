defmodule Rexec.MixProject do
  use Mix.Project

  def project do
    [
      app: :rexec,
      version: "0.1.0",
      elixir: "~> 1.18",
      compilers: [:rexec_native] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
