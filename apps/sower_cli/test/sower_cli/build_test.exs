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

  test "ordinary jobs and obsolete namespaces cannot register through metadata", %{dir: dir} do
    write_manifest(dir)
    metadata = %{"name" => "old", "seed_type" => "nixos"}

    for attr <- [
          nil,
          "package/tool",
          "custom/service",
          "manifest/nixos/host",
          "packages.x86_64-linux.manifest/home/host",
          "packages.x86_64-linux.notseed/service",
          "packages.x86_64-linux.package/nixos/host"
        ] do
      assert [:skip] = Build.seed_candidates(state([build(attr, dir, metadata)]), [])
    end
  end

  test "invalid canonical manifest is an error, never a metadata fallback", %{dir: dir} do
    File.write!(Path.join(dir, "seed.json"), "not json")
    metadata = %{"name" => "old", "seed_type" => "nixos"}

    assert [{:error, {:manifest_failed, _}}] =
             Build.seed_candidates(state([build("nixos/host", dir, metadata)]), [])
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

  defp build(attr, path, meta \\ nil) do
    output = if meta, do: %{"meta" => %{"sower" => %{"seed" => meta}}}, else: %{}

    %Nix.Build{
      store_path: path,
      status: :ok,
      eval: %Nix.Eval{request: %Nix.Eval.Request{attr: attr}, output: output}
    }
  end
end
