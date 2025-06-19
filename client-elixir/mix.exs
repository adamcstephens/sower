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
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:jason, "~> 1.0"},
      # load typedstruct before typed_struct_ecto_changeset
      {:typedstruct, "~> 0.5"},
      {:typed_struct_ecto_changeset, "~> 1.1", override: true},
      {:typed_struct_ctor, "~> 0.1"}
    ]
  end
end
