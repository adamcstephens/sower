sowerMixDevShellHook() {
  local env name target

  mkdir --parents _build
  for env in dev test; do
    mkdir --parents "_build/$env/lib"
    if [ -f _build/.nix-deps ]; then
      while IFS= read -r name; do
        target="_build/$env/lib/$name"
        if [ -L "$target" ]; then
          case "$(readlink "$target")" in
            /nix/store/*) rm --force "$target" ;;
          esac
        fi
      done < _build/.nix-deps
    fi

    while IFS= read -r name; do
      rm --recursive --force "_build/$env/lib/$name"
    done < "$SOWER_MIX_DEPS/names"

    ERL_LIBS="$SOWER_MIX_DEPS/lib/erlang/lib" MIX_BUILD_PREFIX="$env" mixBuildDirHook > /dev/null || return
  done
  ln --symbolic --force "$SOWER_MIX_DEPS/names" _build/.nix-deps
}

sowerMixDevShellHook
