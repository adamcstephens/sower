default:
    just -l

bootstrap:
    @echo "Remove this comment to test" && exit 1

    cp ./dev-client-example.json ./dev-client.json
    cp ./dev-server-example.json ./dev-server.json
    # setup AWS and OIDC secrets
    mix ecto.setup --no-start

check: check-elixir check-rust

check-e2e:
    nix build .#checks.x86_64-linux.default --print-build-logs

check-elixir: check-elixir-format check-elixir-test

check-elixir-format:
    [ -d deps ] || mix deps.get
    mix format --check-formatted

check-elixir-test: dev-services
    mix test

check-rust: check-rust-lint check-rust-test

check-rust-test:
    cargo test

check-rust-lint:
    cargo clippy

clean:
    mix ecto.drop
    git clean -dnx --exclude .dev\* --exclude .jj --exclude .secret.envrc --exclude dev-\*
    # git clean won't purge the deps directories
    rm -rf deps

dev-add-user email:
    mix run apps/sower/priv/repo/seeds-user.exs {{ email }} --no-start

dev-seed-from-local:
    cargo run --quiet -- seed --name $(hostname -s) --type nixos submit --path $(readlink -f /run/current-system) --tag source=dev --tag test=anotherval
    cargo run --quiet -- seed --name $(hostname -s) --type home-manager submit --path $(readlink -f $HOME/.local/state/nix/profiles/home-manager) --tag source=dev

dev-services:
    process-compose list || process-compose up --detached

get-incus-openapi:
    curl https://converter.swagger.io/api/convert?url=https://raw.githubusercontent.com/lxc/incus/refs/heads/main/doc/rest-api.yaml | jq . > apps/incus_client/priv/incus-rest-api.json

format: format-elixir format-rust

format-elixir:
    mix format

format-rust:
    cargo fmt
    nixfmt **/*.nix

mix-nix-lock:
    mix deps.get
    mix deps.nix --output nix/packages/deps.nix --env prod --env test

mix-clean:
    mix deps.clean --unused --unlock
    just mix-nix-lock

openapi-output:
    # remove old sower test app to force correct version
    rm -rf _build/test/lib/sower
    MIX_ENV=test mix deps.get
    MIX_ENV=test mix openapi.spec.json --spec SowerWeb.ApiSpec --pretty=true openapi.json

reset: clean setup

set-version: && openapi-output
    @echo "Current version: $(cat VERSION)"
    @read -p "New version? " new_version; [ -n "$new_version" ] && echo -n $new_version > VERSION
    cargo set-version $(cat VERSION)

setup:
    mix deps.get
    mix deps.compile
    mix ecto.setup
    mix assets.build
    # just dev-add-user <email>
    # just dev-seed-from-local

release: set-version
    mix sower.update_contract_baseline
    git add VERSION openapi.json apps/sower_client/test/fixtures/contract_baseline.json
    jj commit -m "release: version $(cat VERSION)"

release-push:
    git tag -a -m v$(cat VERSION) v$(cat VERSION)
    git push --tags
    jj bookmark move main --to @-
    jj git push
    just release

start: dev-services start-all

start-all:
    nix shell ".#activator" -c iex --sname dev1 -S mix phx.server

start-garden:
    nix shell ".#activator" -c iex --sname garden1 --dot-iex ./.iex-garden.exs -S mix run --no-start

start-server:
    iex --sname server1 --dot-iex ./.iex-server.exs -S mix phx.server --no-start

start-pry:
    iex --dbg pry -S mix phx.server

systemd-analyze unit:
    systemd-analyze security --no-pager --offline=yes --root "$(nix build --no-link --print-out-paths .#checks.x86_64-linux.default.nodes.server.system.build.etc)" {{ unit }}

update: update-nix update-elixir update-npins

update-nix:
    nix flake update --commit-lock-file

update-elixir:
    mix deps.update --all
    mix deps.get
    mix hex.outdated
    pushd apps/sower; MIX_ENV=test mix boruta.gen.migration; popd
    just mix-clean
    just mix-nix-lock
    jj commit -m 'server(chore): update elixir deps' mix.exs mix.lock nix/packages/deps.nix

update-npins:
    npins -d nix/tests/npins update
    if jj diff --name-only | rg '^nix/tests/npins'; then jj commit -m 'chore: npins update' nix/tests/npins; fi
