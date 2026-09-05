default:
    just -l

bootstrap: dev-services dev-client
    [ -f dev-client.json ] || cp ./dev-client-example.json ./dev-client.json
    [ -f dev-server.json ] || cp ./dev-server-example.json ./dev-server.json
    mix deps.get
    mix deps.compile
    mix ecto.setup
    mix assets.build
    -just doctor

check: check-elixir check-rust

check-e2e:
    nix build .#checks.x86_64-linux.default --print-build-logs

check-elixir: check-elixir-format check-elixir-test

check-elixir-audit:
    mix deps.audit

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

dev-client:
    nix build --out-link .dev-client .#sower

dev-seed-from-local:
    cargo run --quiet -- seed --name $(hostname -s) --type nixos submit --path $(readlink -f /run/current-system) --tag source=dev --tag test=anotherval
    cargo run --quiet -- seed --name $(hostname -s) --type home-manager submit --path $(readlink -f $HOME/.local/state/nix/profiles/home-manager) --tag source=dev

dev-services:
    process-compose list || process-compose up --detached

doctor:
    #!/usr/bin/env bash
    set -uo pipefail

    status=0

    report() {
      if [ "$1" = ok ]; then
        echo "  ok       $2"
      else
        echo "  MISSING  $2 -- $3"
        status=1
      fi
    }

    check_path() {
      if [ -e "$1" ]; then report ok "$1"; else report missing "$1" "$2"; fi
    }

    echo "config:"
    check_path dev-server.json "just bootstrap"
    check_path dev-client.json "just bootstrap"

    echo "secrets:"
    for secret in .dev-cookie .dev-secret-key-base .dev-login-token .dev-cloak-ecto .dev-s3-key-id .dev-s3-secret-key .dev-api-token; do
      check_path "$secret" "direnv reload"
    done

    echo "client:"
    check_path .dev-client "just dev-client"

    echo "dependencies:"
    check_path deps "mix deps.get"
    check_path _build "mix deps.compile"

    echo "services:"
    if pg_isready --quiet; then
      report ok postgres
    else
      report missing postgres "just dev-services"
    fi

    database="${PGDATABASE:-sower_dev}"
    if psql --dbname=postgres --list --quiet --tuples-only 2>/dev/null | cut -d'|' -f1 | grep -qw "$database"; then
      report ok "database $database"

      users=$(psql --dbname="$database" --quiet --tuples-only --no-align --command 'select count(*) from users' 2>/dev/null)
      if [ "${users:-0}" -gt 0 ]; then
        report ok "seeded users"
      else
        report missing "seeded users" "sign in at /dev/login, then just dev-add-user <email>"
      fi
    else
      report missing "database $database" "mix ecto.setup"
    fi

    exit $status

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

reset: clean bootstrap

set-version VERSION: && openapi-output
    echo -n {{ VERSION }} > VERSION
    cargo set-version {{ VERSION }}

release: release-version
    mix sower.update_contract_baseline
    jj commit -m "release: version $(cat VERSION)"

release-push:
    jj bookmark move main --to @-
    jj git push
    git tag -a -m v$(cat VERSION) v$(cat VERSION)
    git push --tags
    just release

release-version:
    @echo "Current version: $(cat VERSION)"
    @read -p "New version? " new_version; [ -n "$new_version" ] && just set-version $new_version

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

update: update-nix update-elixir update-npins update-rust

update-nix:
    nix flake update --commit-lock-file

update-elixir:
    mix deps.update --all
    mix deps.get
    mix hex.outdated
    mix hex.audit
    pushd apps/sower; MIX_ENV=test mix boruta.gen.migration; popd
    just mix-clean
    just mix-nix-lock
    jj commit -m 'chore: update elixir deps' apps/*/mix.exs mix.exs mix.lock nix/packages/deps.nix

update-npins:
    npins -d nix/tests/npins update
    if jj diff --name-only | rg '^nix/tests/npins'; then jj commit -m 'chore: npins update' nix/tests/npins; fi

update-rust:
    cargo update
    jj commit -m 'chore: update rust deps' Cargo.lock
