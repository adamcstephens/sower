default:
    just -l

check: check-nix check-elixir

check-elixir:
    unset CI; MIX_ENV=test mix deps.get
    mix test

check-nix:
    nix build .#checks.x86_64-linux.default --print-build-logs

dev: && start
    mix deps.get
    mix deps.compile
    mix ecto.setup

docker-build:
    eval $(nix build --print-build-logs --no-link --print-out-paths --system aarch64-linux .#seed-ci-docker) | docker load
    eval $(nix build --print-build-logs --no-link --print-out-paths --system x86_64-linux .#seed-ci-docker) | docker load

docker-push:
    #!/usr/bin/env bash
    image_name=$(nix eval .#seed-ci-docker.imageName --raw)
    docker manifest rm $image_name:latest || true
    docker push $image_name:latest-aarch64-linux
    docker push $image_name:latest-x86_64-linux
    docker manifest create --amend $image_name:latest $image_name:latest-aarch64-linux $image_name:latest-x86_64-linux
    docker manifest push $image_name:latest

mix-nix-lock:
    mix2nix mix.lock > nix/mix.nix

openapi-output:
    MIX_ENV=test mix openapi.spec.json --spec SowerWeb.ApiSpec --pretty=true openapi.json

openapi-generate: openapi-output
    go generate ./client

set-version version:
    echo -n {{ version }} > VERSION
    cargo generate-lockfile --offline

release:
    git tag -a v$(cat VERSION)
    git push
    git push --tags

start:
    iex -S mix phx.server

start-pry:
    iex --dbg pry -S mix phx.server

start-client:
    watchexec --watch ./cmd/client --restart -- go run ./cmd/client daemon --debug --config ./dev-client.toml

update: update-elixir update-go

update-elixir: && mix-nix-lock
    mix deps.clean --unused --unlock
    mix deps.update --all
    mix deps.get
    mix hex.outdated

update-go: && update-go-hash
    go get -u ./...
    go mod edit -go=$(go version | awk '{print $3}' | sed 's/go//')
    go mod tidy

update-go-hash:
    #!/usr/bin/env bash

    set -eou pipefail

    setKV() {
      sed -i "s|$1 = \".*\"|$1 = \"${2:-}\"|" ./nix/client-package.nix
    }

    setKV vendorHash "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" # Necessary to force clean build.

    set +e
    VENDOR_HASH=$(nix build --no-link .#client 2>&1 >/dev/null | grep "got:" | cut -d':' -f2 | sed 's| ||g')
    set -e

    if [ -n "${VENDOR_HASH:-}" ]; then
      setKV vendorHash ${VENDOR_HASH}
    else
      echo "Update failed. VENDOR_HASH is empty."
      exit 1
    fi

    git diff ./nix/client-package.nix
