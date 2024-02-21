defmodule SowerTree.MixProject do
  use Mix.Project

  def project do
    [
      app: :sower_tree,
      version: "0.1.0",
      deps: deps(),
      escript: [
        main_module: SowerTree.CLI
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.4.0"}
    ]
  end
end
