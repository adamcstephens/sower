defmodule SowerCli.BuildTest do
  use ExUnit.Case, async: true

  alias SowerCli.Build

  @artifact "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"

  setup do
    dir = Path.join(System.tmp_dir!(), "sower-seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  @tag timeout: 120_000
  test "discovers and builds jobs without forcing metadata, then reads the seed manifest" do
    fixture = Path.expand("../fixtures/seed-jobs.nix", __DIR__)
    {:ok, discovery} = Nix.Eval.run(fixture)
    assert Enum.sort(Enum.map(discovery.output, & &1.attr)) == ["package/tool", "seed/host"]

    evals =
      Enum.map(discovery.output, fn request ->
        assert {_, 0} =
                 System.cmd("nix-instantiate", [fixture, "--attr", inspect(request.attr)],
                   stderr_to_stdout: true
                 )

        {:ok, eval} = Nix.Eval.run(%{request | attr: inspect(request.attr)})
        %{eval | request: request}
      end)

    {:ok, result} = Nix.Build.Jobs.run(evals)
    ordinary = Enum.find(result.results, &(&1.eval.request.attr == "package/tool"))
    wrapper = Enum.find(result.results, &(&1.eval.request.attr == "seed/host"))
    assert File.read!(Path.join(ordinary.store_path, "ready")) == "ready\n"
    repo_tag = %SowerClient.SeedTag{key: "revision", value: "abc"}
    assert [:skip] = Build.seed_candidates(state([ordinary]), [repo_tag])
    assert [{:ok, seed}] = Build.seed_candidates(state([wrapper]), [repo_tag])
    assert seed.name == "manifest-host"
    assert seed.seed_type == "nixos"
    assert seed.artifact == ordinary.store_path

    assert Enum.map(seed.tags, &{&1.key, &1.value}) ==
             [{"source", "cli"}, {"origin", "manifest"}, {"revision", "abc"}]
  end

  test "canonical wrappers register the manifest target and compose tags", %{dir: dir} do
    write_manifest(dir)
    repo_tag = %SowerClient.SeedTag{key: "revision", value: "abc"}

    for attr <- ["nixos/host", "home/host", "seed/service"] do
      assert [{:ok, seed}] = Build.seed_candidates(state([build(attr, dir)]), [repo_tag])
      assert seed.name == "host"
      assert seed.artifact == @artifact
      assert seed.artifact != dir
      assert seed.seed_type == "nixos"

      assert Enum.map(seed.tags, &{&1.key, &1.value}) ==
               [{"source", "cli"}, {"system", "x86_64-linux"}, {"revision", "abc"}]
    end
  end

  test "qualified canonical jobs are recognized", %{dir: dir} do
    write_manifest(dir)

    for attr <- [
          "packages.x86_64-linux.nixos/host",
          "packages.aarch64-linux.home/host",
          "legacyPackages.x86_64-linux.seed/service"
        ] do
      assert [{:ok, seed}] = Build.seed_candidates(state([build(attr, dir)]), [])
      assert seed.name == "host"
      assert seed.artifact == @artifact
    end
  end

  test "ordinary jobs and obsolete namespaces do not register", %{dir: dir} do
    write_manifest(dir)

    for attr <- [
          nil,
          "package/tool",
          "custom/service",
          "manifest/nixos/host",
          "packages.x86_64-linux.manifest/home/host",
          "packages.x86_64-linux.notseed/service",
          "packages.x86_64-linux.package/nixos/host"
        ] do
      assert [:skip] = Build.seed_candidates(state([build(attr, dir)]), [])
    end
  end

  test "invalid canonical manifest is a registration error", %{dir: dir} do
    File.write!(Path.join(dir, "seed.json"), "not json")

    assert [{:error, {:manifest_failed, _}}] =
             Build.seed_candidates(state([build("nixos/host", dir)]), [])
  end

  test "missing and unsupported canonical manifests report registration errors", %{dir: dir} do
    assert [{:error, {:manifest_failed, :enoent}}] =
             Build.seed_candidates(state([build("home/host", dir)]), [])

    write_manifest(dir, 2)

    assert [{:error, {:manifest_failed, _}}] =
             Build.seed_candidates(state([build("seed/service", dir)]), [])
  end

  test "registration errors and malformed manifests are retained", %{dir: dir} do
    write_manifest(dir)
    client = Req.new(base_url: "http://127.0.0.1:0", retry: false)
    state = %{state([build("nixos/host", dir)]) | flags: %{non_authoritative: false}}
    SowerCli.Output.init(debug: true)

    ExUnit.CaptureIO.capture_io(fn ->
      assert [{:error, %Req.TransportError{reason: :econnrefused}}] =
               Build.register_seeds(state, client, [])

      File.write!(Path.join(dir, "seed.json"), "{}")
      assert [{:error, {:manifest_failed, _}}] = Build.register_seeds(state, client, [])
    end)
  end

  defp write_manifest(dir, version \\ 1) do
    File.write!(
      Path.join(dir, "seed.json"),
      Jason.encode!(%{
        version: version,
        name: "host",
        seed_type: "nixos",
        artifact: @artifact,
        tags: %{system: "x86_64-linux"}
      })
    )
  end

  defp state(builds) do
    %Build{builds: builds, options: %{tag: ["source=cli"]}}
  end

  defp build(attr, path) do
    %Nix.Build{
      store_path: path,
      status: :ok,
      eval: %Nix.Eval{request: %Nix.Eval.Request{attr: attr}}
    }
  end
end
