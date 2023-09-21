default:
    just -l

dev:
    mix ecto.setup
    iex -S mix run --no-halt

nix-lock:
    mix2nix mix.lock > nix/mix.nix

update: && nix-lock
    mix deps.update --all
