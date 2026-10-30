Mix.start()

Mix.Project.in_project(:sower_umbrella, ".", fn _ ->
  Mix.Task.run("loadconfig")
  # Regeneration must work with the previous build after mix.lock changes.
  Mix.Task.run("loadpaths", ["--no-deps-check"])

  Mix.Task.run("deps.nix", [
    "--output",
    "nix/packages/deps.nix",
    "--env",
    "dev",
    "--env",
    "prod",
    "--env",
    "test"
  ])

  environments =
    Map.new([:dev, :prod, :test], fn env ->
      names =
        Mix.Dep.Converger.converge(env: env)
        |> Enum.filter(& &1.scm.fetchable?())
        |> Enum.map(& &1.app)
        |> Enum.sort()

      {env, names}
    end)

  File.write!("nix/packages/deps-envs.json", Jason.encode!(environments, pretty: true) <> "\n")
end)
