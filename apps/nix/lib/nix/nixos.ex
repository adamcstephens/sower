defmodule Nix.NixOS do
  use Nix.Profile, type: :nixos

  @impl Nix.Profile
  def current_path() do
    "/run/current-system"
  end

  @impl Nix.Profile
  def profile_path() do
    "/nix/var/nix/profiles/system"
  end
end
