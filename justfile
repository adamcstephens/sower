default:
    just -l

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

nix-lock:
    mix2nix mix.lock > nix/mix.nix

set-version version:
    echo -n {{ version }} > VERSION
    sed -i 's/^version = ".*"/version = "{{ version }}"/' client/Cargo.toml
    cargo generate-lockfile

release:
    git tag -a v$(cat VERSION)

start:
    iex -S mix phx.server

update-elixir: && nix-lock
    mix deps.update --all
    mix deps.clean --unused --unlock

update-rust:
    cargo update
