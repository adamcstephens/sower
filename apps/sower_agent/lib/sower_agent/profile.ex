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
      |> Enum.reject(&is_nil/1)

    AgentSeedsReport.cast!(%{profiles: profiles})
  end

  @doc """
  Collects NixOS system profile if available.
  """
  def collect_nixos() do
    collect_profile(Nix.NixOS, "/nix/var/nix/profiles/system")
  rescue
    e ->
      Logger.warning(msg: "Failed to collect NixOS profile", error: Exception.message(e))
      nil
  end

  @doc """
  Collects HomeManager profile if available.
  """
  def collect_home_manager() do
    collect_profile(Nix.HomeManager, home_manager_profile_path())
  rescue
    e ->
      Logger.warning(msg: "Failed to collect HomeManager profile", error: Exception.message(e))
      nil
  end

  defp home_manager_profile_path() do
    xdg_state = System.get_env("XDG_STATE_HOME", "#{System.get_env("HOME")}/.local/state")
    "#{xdg_state}/nix/profiles/home-manager"
  end

  defp collect_profile(module, profile_path) do
    # Check if profile directory exists
    unless File.exists?(profile_path) do
      Logger.debug(msg: "Profile path does not exist", path: profile_path)
      throw(:profile_not_found)
    end

    state = module.get_state()

    # Convert all available generations
    current_path = state.current.path

    generations =
      state.profiles
      |> Enum.map(&to_agent_seed_generation(&1, current_path))

    # Add current generation if not already in profiles list
    generations =
      if Enum.any?(generations, &(&1.path == current_path)) do
        generations
      else
        [to_agent_seed_generation(state.current, current_path) | generations]
      end

    AgentSeedProfile.cast!(%{
      profile_path: profile_path,
      tags: state.tags,
      generations: generations
    })
  catch
    :profile_not_found -> nil
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
