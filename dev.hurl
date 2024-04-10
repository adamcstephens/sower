POST http://[::1]:4000/api/seeds
Content-Type: application/json

{
  "name": "yank",
  "type": "nixos",
  "out_path": "/nix/store/6daslzwpm9fzr6sw11irw1jcnsmspmhy-source"
}

# GET http://[::1]:4000/api/seeds
#
# GET http://[::1]:4000/api/seeds/latest?name=yank2&type=nixos
