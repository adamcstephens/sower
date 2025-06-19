default:
    just -l

check: check-nix check-elixir check-go

check-elixir: check-elixir-format check-elixir-test

check-elixir-format:
    mix deps.get
    mix format --check-formatted

check-elixir-test:
    unset CI; MIX_ENV=test mix deps.get
    mix test

check-go: check-go-lint

check-go-lint:
    golangci-lint run

check-nix:
    nix build .#checks.x86_64-linux.default --print-build-logs

dev: && start
    mix deps.get
    mix deps.compile
    mix ecto.setup
    mix assets.build

dev-seed-from-local:
    go run ./cmd/client seed submit --create --name $(hostname -s) --type nixos --path $(readlink -f /run/booted-system)
    go run ./cmd/client seed submit --create --name $(hostname -s) --type home-manager --path $(readlink -f $HOME/.local/state/nix/profiles/home-manager)

dev-services:
    process-compose list || process-compose up --detached

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
    mix deps.nix --output nix/packages/deps.nix

mix-clean:
    mix deps.clean --unused --unlock

openapi-output:
    # remove old sower test app to force correct version
    rm -rf _build/test/lib/sower
    MIX_ENV=test mix openapi.spec.json --spec SowerWeb.ApiSpec --pretty=true openapi.json

openapi-generate: openapi-output
    go generate ./client

set-version: && openapi-generate
    @echo "Current version: $(cat VERSION)"
    @read -p "New version? " new_version; [ -n "$new_version" ] && echo -n $new_version > VERSION

release: set-version
    git add VERSION openapi.json
    git commit -m "release: version $(cat VERSION)"

release-push:
    git tag -a -m v$(cat VERSION) v$(cat VERSION)
    git push
    git push --tags
    just release

start: dev-services
    iex -S mix phx.server

start-pry:
    iex --dbg pry -S mix phx.server

start-client:
    watchexec --watch ./cmd/client --restart -- go run ./cmd/client daemon --debug --config ./dev-client.toml

update: update-nix update-elixir update-go

update-nix:
    nix flake update --commit-lock-file

update-elixir: mix-clean
    mix deps.update --all
    mix deps.get
    mix hex.outdated
    just mix-nix-lock
    git add mix.exs mix.lock nix/packages/deps.nix
    git commit -m 'server(chore): update elixir deps' -- mix.exs mix.lock nix/packages/deps.nix

update-go:
    go get -u ./...
    go mod edit -go=$(go version | awk '{print $3}' | sed 's/go//')
    go mod tidy
    just update-go-hash
    git add go.mod go.sum nix/packages/client.nix
    git commit -m 'server(chore): update go deps' -- go.mod go.sum nix/packages/client.nix

update-go-hash:
    #!/usr/bin/env bash

    set -eou pipefail

    setKV() {
      sed -i "s|$1 = \".*\"|$1 = \"${2:-}\"|" ./nix/packages/client.nix
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

    git diff ./nix/packages/client.nix
