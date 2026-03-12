default:
    just -l

check: check-elixir check-go

check-e2e:
    nix build .#checks.x86_64-linux.default --print-build-logs

check-elixir: check-elixir-format check-elixir-test

check-elixir-format:
    [ -d deps ] || mix deps.get
    mix format --check-formatted

check-elixir-test: dev-services
    mix test

check-go: check-go-lint check-go-test

check-go-lint:
    golangci-lint run

check-go-test:
    go test ./...

clean:
    mix ecto.drop
    git clean -dnx --exclude .dev\* --exclude .jj --exclude .secret.envrc --exclude dev-\*
    # git clean won't purge the deps directories
    rm -rf deps

dev-add-user email:
    mix run apps/sower/priv/repo/seeds-user.exs {{ email }} --no-start

dev-seed-from-local:
    go run ./cmd/cli seed submit --name $(hostname -s) --type nixos --path $(readlink -f /run/current-system) --tag source=dev  --tag test=anotherval
    go run ./cmd/cli seed submit --name $(hostname -s) --type home-manager --path $(readlink -f $HOME/.local/state/nix/profiles/home-manager) --tag source=dev

dev-services:
    process-compose list || process-compose up --detached

get-incus-openapi:
    curl https://converter.swagger.io/api/convert?url=https://raw.githubusercontent.com/lxc/incus/refs/heads/main/doc/rest-api.yaml | jq . > apps/incus_client/priv/incus-rest-api.json

mix-nix-lock:
    mix deps.get
    mix deps.nix --output nix/packages/deps.nix

mix-clean:
    mix deps.clean --unused --unlock
    just mix-nix-lock

openapi-output:
    # remove old sower test app to force correct version
    rm -rf _build/test/lib/sower
    MIX_ENV=test mix deps.get
    MIX_ENV=test mix openapi.spec.json --spec SowerWeb.ApiSpec --pretty=true openapi.json

openapi-generate: openapi-output
    go generate ./client-go

reset: clean setup

set-version: && openapi-generate
    @echo "Current version: $(cat VERSION)"
    @read -p "New version? " new_version; [ -n "$new_version" ] && echo -n $new_version > VERSION

setup:
    mix deps.get
    mix deps.compile
    mix ecto.setup
    mix assets.build
    # just dev-add-user <email>
    # just dev-seed-from-local

release: set-version
    git add VERSION openapi.json
    jj commit -m "release: version $(cat VERSION)"

release-push:
    git tag -a -m v$(cat VERSION) v$(cat VERSION)
    git push --tags
    jj git push
    just release

start: dev-services start-all

start-all:
    nix shell ".#activator" -c iex --sname dev1 -S mix phx.server

start-agent:
    nix shell ".#activator" -c iex --sname agent1 --dot-iex ./.iex-agent.exs -S mix run --no-start

start-server:
    iex --sname server1 --dot-iex ./.iex-server.exs -S mix phx.server --no-start

start-pry:
    iex --dbg pry -S mix phx.server

update: update-nix update-elixir update-go update-npins

update-nix:
    nix flake update --commit-lock-file

update-elixir:
    mix deps.update --all
    mix deps.get
    mix hex.outdated
    just mix-clean
    just mix-nix-lock
    jj commit -m 'server(chore): update elixir deps' mix.exs mix.lock nix/packages/deps.nix

update-go:
    go get -u ./...
    go mod edit -go=$(go version | awk '{print $3}' | sed 's/go//')
    go mod tidy
    just update-go-hash activator
    just update-go-hash go-cli
    jj commit -m 'server(chore): update go deps' go.mod go.sum nix/packages/activator.nix nix/packages/go-cli.nix

update-go-hash app:
    #!/usr/bin/env bash

    set -eou pipefail

    setKV() {
      sed -i "s|$1 = \".*\"|$1 = \"${2:-}\"|" ./nix/packages/{{ app }}.nix
    }

    setKV vendorHash "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" # Necessary to force clean build.

    set +e
    VENDOR_HASH=$(nix build --no-link .#{{ app }} 2>&1 >/dev/null | grep "got:" | cut -d':' -f2 | sed 's| ||g')
    set -e

    if [ -n "${VENDOR_HASH:-}" ]; then
      setKV vendorHash ${VENDOR_HASH}
    else
      echo "Update failed. VENDOR_HASH is empty."
      exit 1
    fi

    git diff ./nix/packages/{{ app }}.nix

update-npins:
    npins -d nix/tests/npins update
    if jj diff --name-only | rg '^nix/tests/npins'; then jj commit -m 'chore: npins update' nix/tests/npins; fi
