{
  runCommand,
  callPackage,
  callPackages,
  beamPackages,
  coreutils,
  gnugrep,
}:
let
  releaseDeps = callPackages ./umbrella-deps.nix { inherit beamPackages; };
  devDeps = callPackages ./umbrella-deps.nix {
    inherit beamPackages;
    mixEnvs = [ "dev" ];
  };
  inherit (releaseDeps) jason;
  bundle = callPackage ./dev-mix-deps.nix {
    inherit beamPackages;
    mixNixDeps = { inherit jason; };
  };
in
assert !(releaseDeps ? tidewave);
assert devDeps ? tidewave;
runCommand "mix-dev-shell-check"
  {
    env.LANG = "C.UTF-8";
    nativeBuildInputs = [
      beamPackages.elixir
      beamPackages.hex
      beamPackages.mixBuildDirHook
      coreutils
      gnugrep
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    export HEX_OFFLINE=1
    mkdir --parents "$HOME" project/deps project/lib project/test
    cd project

    cat > mix.exs <<'ELIXIR'
    defmodule NixShellCheck.MixProject do
      use Mix.Project

      def project do
        [app: :nix_shell_check, version: "0.1.0", deps: [{:jason, "~> 1.4"}]]
      end

      def application, do: []
    end
    ELIXIR
    cat > lib/nix_shell_check.ex <<'ELIXIR'
    defmodule NixShellCheck do
      def round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
    end
    ELIXIR
    cat > test/test_helper.exs <<'ELIXIR'
    ExUnit.start()
    ELIXIR
    cat > test/nix_shell_check_test.exs <<'ELIXIR'
    defmodule NixShellCheckTest do
      use ExUnit.Case

      test "uses the Nix-compiled JSON dependency" do
        assert NixShellCheck.round_trip(["hello", 42, true]) == ["hello", 42, true]
      end
    end
    ELIXIR
    cp ${../../mix.lock} mix.lock
    cp --recursive ${jason.src} deps/jason
    chmod --recursive u+w deps/jason

    for environment in dev test; do
      mkdir --parents "_build/$environment/lib/local_app/ebin" \
        "_build/$environment/lib/jason/ebin"
      printf 'local artifact\n' > "_build/$environment/lib/local_app/ebin/keep"
      printf 'obsolete dependency artifact\n' > "_build/$environment/lib/jason/ebin/obsolete"
      ln --symbolic ${jason} "_build/$environment/lib/former_dependency"
    done
    printf 'jason\nformer_dependency\n' > _build/.nix-deps

    export SOWER_MIX_DEPS=${bundle}
    source ${../flake/mix-dev-shell.sh}

    assert_dependency_links() {
      for environment in dev test; do
        dependency="_build/$environment/lib/jason"
        test -L "$dependency"
        case "$(readlink --canonicalize "$dependency")" in
          /nix/store/*) ;;
          *) echo "Dependency is not store-backed: $dependency" >&2; exit 1 ;;
        esac
        test -f "$dependency/ebin/Elixir.Jason.beam"
        test -f "$dependency/.mix/compile.elixir_scm"
        test ! -e "$dependency/ebin/obsolete"
        test ! -L "_build/$environment/lib/former_dependency"
        test ! -e "_build/$environment/lib/former_dependency"
        test "$(cat "_build/$environment/lib/local_app/ebin/keep")" = 'local artifact'
      done
    }
    assert_dependency_links
    dev_target=$(readlink _build/dev/lib/jason)
    test_target=$(readlink _build/test/lib/jason)
    source ${../flake/mix-dev-shell.sh}
    assert_dependency_links
    test "$(readlink _build/dev/lib/jason)" = "$dev_target"
    test "$(readlink _build/test/lib/jason)" = "$test_target"
    test "$(cat _build/.nix-deps)" = jason

    mix compile > compile.log 2>&1 || { cat compile.log; exit 1; }
    MIX_ENV=test mix test > test.log 2>&1 || { cat test.log; exit 1; }
    cat compile.log test.log
    if grep --extended-regexp '==> jason|Generated jason app' compile.log test.log; then
      echo 'Mix unexpectedly compiled the Nix-provided dependency' >&2
      exit 1
    fi
    assert_dependency_links
    test "$(readlink _build/dev/lib/jason)" = "$dev_target"
    test "$(readlink _build/test/lib/jason)" = "$test_target"

    mv mix.lock saved.lock
    if mix compile > missing-lock.log 2>&1; then
      echo 'Mix accepted an unlocked dependency' >&2
      cat missing-lock.log
      exit 1
    fi
    mv saved.lock mix.lock
    assert_dependency_links

    touch "$out"
  ''
