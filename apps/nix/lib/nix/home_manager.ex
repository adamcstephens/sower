defmodule Nix.HomeManager do
  use Nix.Profile, type: :home_manager

  @impl Nix.Profile
  def current_path() do
    profile_path()
  end

  @impl Nix.Profile
  def profile_path() do
    "#{System.fetch_env!("XDG_STATE_HOME")}/nix/profiles/home-manager"
  end
end
