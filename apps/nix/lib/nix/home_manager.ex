defmodule Nix.HomeManager do
  use Nix.Profile

  @impl Nix.Profile
  def profile_path() do
    "#{System.fetch_env!("XDG_STATE_HOME")}/nix/profiles/home-manager"
  end

  @impl Nix.Profile
  def tags() do
    %{
      "user" => System.fetch_env!("USER")
    }
  end
end
