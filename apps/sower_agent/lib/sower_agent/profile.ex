defmodule SowerAgent.Profile do
  @moduledoc """
  Collects Nix profile generation data for reporting to the server.
  """

  require Logger

  alias SowerClient.Orchestration.{AgentSeedGeneration, AgentSeedProfile, AgentSeedsReport}

  @doc """
  Collects all available Nix profiles with their generations.

  Returns an AgentSeedsReport struct containing NixOS and HomeManager profiles.
  Profiles that fail to load are logged as warnings and excluded from the report.
  """
  def collect_all_profiles() do
    profiles =
      [
        collect_nixos(),
        collect_home_manager()
      ]
      |> Enum.reject(fn {result, _} -> result == :error end)
      |> Enum.map(fn {_, profile} -> profile end)

    AgentSeedsReport.cast!(%{profiles: profiles})
  end

  def collect_nixos() do
    collect_profile(Nix.NixOS, "/nix/var/nix/profiles/system")
  end

  def collect_home_manager() do
    collect_profile(Nix.HomeManager, home_manager_profile_path())
  end

  def home_manager_profile_path() do
    xdg_state = System.get_env("XDG_STATE_HOME", "#{System.get_env("HOME")}/.local/state")
    "#{xdg_state}/nix/profiles/home-manager"
  end

  def collect_profile(module, profile_path) do
    if File.exists?(profile_path) do
      do_collect_profile(module, profile_path)
    else
      Logger.debug(msg: "Profile path does not exist", path: profile_path)
      {:error, :profile_not_found}
    end
  end

  def do_collect_profile(module, profile_path) do
    state = module.get_state()

    generations =
      state.profiles
      |> Enum.map(&to_agent_seed_generation(&1, state.current.path))

    generations =
      if Enum.any?(generations, &(&1.path == state.current.path)) do
        generations
      else
        [to_agent_seed_generation(state.current, state.current.path) | generations]
      end

    {:ok,
     AgentSeedProfile.cast!(%{
       profile_path: profile_path,
       tags: state.tags,
       generations: generations
     })}
  end

  defp to_agent_seed_generation(%Nix.Profile.Generation{} = gen, current_path) do
    AgentSeedGeneration.cast!(%{
      path: gen.path,
      link: gen.link,
      created: DateTime.to_iso8601(gen.created),
      generation_number: extract_generation_number(gen.link),
      is_current: gen.path == current_path
    })
  end

  @doc """
  Extracts generation number from a profile symlink path.

  ## Examples

      iex> SowerAgent.Profile.extract_generation_number("/nix/var/nix/profiles/system-42-link")
      42

      iex> SowerAgent.Profile.extract_generation_number("/nix/var/nix/profiles/system")
      nil
  """
  def extract_generation_number(link) do
    case Regex.run(~r/-(\d+)-link$/, link) do
      [_, num] -> String.to_integer(num)
      nil -> nil
    end
  end
end
