default:
    just -l

# db:
#     process-compose up -t=false
#
dev: && start
    mix deps.get
    mix deps.compile
    mix ecto.setup

nix-lock:
    mix2nix mix.lock > nix/mix.nix

start:
    iex -S mix phx.server

update: && nix-lock
    mix deps.update --all
    mix deps.clean --unused --unlock
