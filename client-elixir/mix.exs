defmodule SowerClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :sower_client,
      version: "0.1.0",
      elixir: "~> 1.18",
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
    [
      {:typed_struct_ctor, "~> 0.1"},
      {:jason, "~> 1.0"},
      {:typedstruct, "~> 0.5"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end
end
