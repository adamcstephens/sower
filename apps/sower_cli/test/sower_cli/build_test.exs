defmodule SowerCli.BuildTest do
  use ExUnit.Case, async: true

  alias SowerCli.Build

  @artifact "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"

  setup do
    dir = Path.join(System.tmp_dir!(), "sower-manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "manifest target and tags win over paired legacy metadata", %{dir: dir} do
    write_manifest(dir)
    manifest = build("manifest/nixos/host", dir)
    legacy = build("nixos/host", @artifact, %{"name" => "old", "seed_type" => "nixos"})
    ordinary = build("package/tool", "/nonexistent")
    state = state([legacy, ordinary, manifest])
    repo_tag = %SowerClient.SeedTag{key: "revision", value: "abc"}

    assert [:skip, :skip, {:ok, seed}] = Build.seed_candidates(state, [repo_tag])
    assert seed.name == "host"
    assert seed.artifact == @artifact
    assert seed.seed_type == "nixos"

    assert Enum.map(seed.tags, &{&1.key, &1.value}) ==
             [{"source", "cli"}, {"system", "x86_64-linux"}, {"revision", "abc"}]
  end

  test "custom manifest jobs and unmatched legacy jobs register", %{dir: dir} do
    write_manifest(dir)
    legacy = build("custom/old", @artifact, %{"name" => "old", "seed_type" => "service"})

    assert [{:ok, custom}, {:ok, old}] =
             Build.seed_candidates(state([build("manifest/custom/service", dir), legacy]), [])

    assert custom.artifact == @artifact
    assert old.name == "old"
    assert old.artifact == @artifact
  end

  test "invalid paired manifest is an error, not a fallback to metadata", %{dir: dir} do
    File.write!(Path.join(dir, "seed.json"), "not json")
    legacy = build("nixos/host", @artifact, %{"name" => "old", "seed_type" => "nixos"})

    assert [:skip, {:error, {:manifest_failed, _}}] =
             Build.seed_candidates(state([legacy, build("manifest/nixos/host", dir)]), [])
  end

  test "missing and unsupported manifests report registration errors", %{dir: dir} do
    assert [{:error, {:manifest_failed, :enoent}}] =
             Build.seed_candidates(state([build("manifest/home/host", dir)]), [])

    write_manifest(dir, 2)

    assert [{:error, {:manifest_failed, _}}] =
             Build.seed_candidates(state([build("manifest/home/host", dir)]), [])
  end

  test "qualified flake jobs suppress their corresponding legacy job", %{dir: dir} do
    write_manifest(dir)
    prefix = "packages.x86_64-linux."

    legacy =
      build(prefix <> "home/host", @artifact, %{"name" => "old", "seed_type" => "home-manager"})

    assert [:skip, {:ok, seed}] =
             Build.seed_candidates(
               state([legacy, build(prefix <> "manifest/home/host", dir)]),
               []
             )

    assert seed.name == "host"
  end

  test "registration errors and malformed manifests are retained", %{dir: dir} do
    write_manifest(dir)
    client = Req.new(base_url: "http://127.0.0.1:0", retry: false)
    state = %{state([build("manifest/nixos/host", dir)]) | flags: %{non_authoritative: false}}
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
