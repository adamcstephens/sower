{
  beamPackages,
  callPackages,
  lib,
  runCommand,
  writeText,
  mixNixDeps ? callPackages ./umbrella-deps.nix {
    inherit beamPackages;
    mixEnvs = [
      "dev"
      "test"
    ];
  },
}:
let
  manifests = writeText "mix-dev-manifests.exs" ''
    [root, lockfile] = System.argv()
    locks = Mix.Dep.Lock.read(lockfile)

    names =
      for path <- Path.wildcard(Path.join(root, "lib/erlang/lib/*")) do
        name = path |> Path.basename() |> String.split("-", parts: 2) |> hd()
        lock = Map.fetch!(locks, String.to_existing_atom(name))

        scm =
          case elem(lock, 0) do
            :hex -> Hex.SCM
            :git -> Mix.SCM.Git
          end

        Mix.Dep.ElixirSCM.update(Path.join(path, ".mix"), scm, lock)
        name
      end

    File.write!(Path.join(root, "names"), Enum.join(names, "\n") <> "\n")
  '';
in
runCommand "sower-dev-mix-deps"
  {
    nativeBuildInputs = [ beamPackages.elixir ];
    env.LANG = "C.UTF-8";
  }
  ''
    mkdir --parents "$out/lib/erlang/lib"
    ${lib.concatMapStringsSep "\n" (dep: ''
      for app in ${dep}/lib/erlang/lib/*; do
        dest="$out/lib/erlang/lib/$(basename "$app")"
        mkdir --parents "$dest"
        for entry in "$app"/*; do
          ln --symbolic "$entry" "$dest/"
        done
      done
    '') (builtins.attrValues mixNixDeps)}
    elixir ${manifests} "$out" ${../../mix.lock}
  ''
