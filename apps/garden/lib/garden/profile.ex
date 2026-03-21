defmodule Garden.Profile do
  @moduledoc """
  Collects Nix profile generation data for reporting to the server.
  """

  require Logger

  alias SowerClient.Orchestration.{GardenSeedGeneration, GardenSeedProfile, GardenSeedsReport}

  @doc """
  Collects profiles based on the provided targets.

  Targets should be a list of maps with :type and :path keys:
  - `%{type: "nixos", path: "/nix/var/nix/profiles/system"}`
  - `%{type: "home-manager", path: "/home/user/.local/state/nix/profiles/home-manager"}`

  Returns an GardenSeedsReport struct containing only the requested profiles.
  Profiles that fail to load are logged as warnings and excluded from the report.

  ## Examples

      iex> targets = [%{type: "nixos", path: "/nix/var/nix/profiles/system"}]
      iex> Garden.Profile.collect_profiles(targets)
      %SowerClient.Orchestration.GardenSeedsReport{profiles: [...]}
  """
  def collect_profiles(targets) when is_list(targets) do
    profiles =
      targets
      |> Enum.map(&collect_target/1)
      |> Enum.reject(fn {result, _} -> result == :error end)
      |> Enum.map(fn {_, profile} -> profile end)

    GardenSeedsReport.cast!(%{profiles: profiles})
  end

  @doc """
  Builds profile targets from subscriptions.

  For nixos subscriptions: generates target with system profile path.
  For home-manager subscriptions: extracts username from rules and generates
  profile path for each unique user.

  ## Examples

      iex> subs = [%{seed_type: "nixos", seed_name: "host", rules: []}]
      iex> Garden.Profile.build_profile_targets(subs)
      [%{type: "nixos", path: "/nix/var/nix/profiles/system"}]

      iex> subs = [%{seed_type: "home-manager", seed_name: "alice@host", rules: [%{key: "username", value: "alice"}]}]
      iex> Garden.Profile.build_profile_targets(subs)
      [%{type: "home-manager", path: "/home/alice/.local/state/nix/profiles/home-manager"}]
  """
  def build_profile_targets(subscriptions) when is_list(subscriptions) do
    subscriptions
    |> Enum.flat_map(&subscription_to_targets/1)
    |> Enum.uniq()
  end

  defp subscription_to_targets(%{seed_type: "nixos"}) do
    [%{type: "nixos", path: "/nix/var/nix/profiles/system"}]
  end

  defp subscription_to_targets(%{seed_type: "home-manager", rules: rules}) do
    username = extract_username_from_rules(rules)

    case home_manager_profile_path(username) do
      {:ok, path} ->
        [%{type: "home-manager", path: path}]

      {:error, reason} ->
        Logger.warning(
          msg: "Could not determine home-manager profile path",
          username: username,
          reason: reason
        )

        []
    end
  end

  defp subscription_to_targets(_), do: []

  defp extract_username_from_rules(rules) when is_list(rules) do
    case Enum.find(rules, &(&1.key == "username")) do
      %{value: username} when is_binary(username) and username != "" ->
        username

      _ ->
        nil
    end
  end

  defp extract_username_from_rules(_), do: nil

  @doc """
  Collects profiles for the given subscriptions.

  Builds profile targets from subscriptions and collects profiles for each target.
  Returns an empty report if no subscriptions exist (allowing server cleanup).

  ## Examples

      iex> subs = [%{seed_type: "nixos", seed_name: "host", rules: []}]
      iex> Garden.Profile.collect_profiles_for_subscriptions(subs)
      %SowerClient.Orchestration.GardenSeedsReport{profiles: [...]}

      iex> Garden.Profile.collect_profiles_for_subscriptions([])
      %SowerClient.Orchestration.GardenSeedsReport{profiles: []}
  """
  def collect_profiles_for_subscriptions(subscriptions) when is_list(subscriptions) do
    targets = build_profile_targets(subscriptions)
    collect_profiles(targets)
  end

  @doc """
  Returns the home-manager profile path for the current user.
  """
  def home_manager_profile_path(user \\ nil)

  def home_manager_profile_path(nil) do
    case System.get_env("XDG_STATE_HOME") do
      nil ->
        # Get current user and look up their home directory
        case get_user_home(System.fetch_env!("USER")) do
          {:ok, home} ->
            {:ok, "#{home}/.local/state/nix/profiles/home-manager"}

          {:error, reason} ->
            {:error, reason}
        end

      xdg_state ->
        {:ok, "#{xdg_state}/nix/profiles/home-manager"}
    end
  end

  def home_manager_profile_path(username) when is_binary(username) do
    case get_user_home(username) do
      {:ok, home} ->
        {:ok, "#{home}/.local/state/nix/profiles/home-manager"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the home directory for a user using getent, falling back to /etc/passwd,
  then assuming /home/<username> as a last resort.

  Returns `{:ok, home_path}` or `{:error, :user_not_found}`.
  """
  def get_user_home(username) when is_binary(username) do
    case System.cmd("getent", ["passwd", username], stderr_to_stdout: true) do
      {output, 0} ->
        parse_passwd_home(output)

      {_output, _exit_code} ->
        fallback_get_user_home(username)
    end
  end

  defp parse_passwd_home(output) do
    # Format: username:password:uid:gid:gecos:home:shell
    case String.split(String.trim(output), ":") do
      parts when length(parts) >= 6 ->
        {:ok, Enum.at(parts, 5)}

      _ ->
        {:error, :invalid_passwd_format}
    end
  end

  defp fallback_get_user_home(username) do
    case File.read("/etc/passwd") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "#{username}:"))
        |> case do
          nil ->
            # Last resort: assume /home/<username>
            {:ok, "/home/#{username}"}

          line ->
            parse_passwd_home(line)
        end

      {:error, reason} ->
        # Can't read /etc/passwd, assume /home/<username>
        Logger.debug(
          msg: "Could not read /etc/passwd, assuming /home/<username>",
          username: username,
          reason: reason
        )

        {:ok, "/home/#{username}"}
    end
  end

  defp collect_target(%{type: "nixos", path: path}) do
    collect_profile(Nix.NixOS, path)
  end

  defp collect_target(%{type: "home-manager", path: path}) do
    collect_profile(Nix.HomeManager, path)
  end

  defp collect_target(target) do
    Logger.warning(msg: "Unknown profile target type", target: target)
    {:error, :unknown_target_type}
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
      |> Enum.map(&to_garden_seed_generation(&1, state.current.path))

    generations =
      if Enum.any?(generations, &(&1.path == state.current.path)) do
        generations
      else
        [to_garden_seed_generation(state.current, state.current.path) | generations]
      end

    {:ok,
     GardenSeedProfile.cast!(%{
       profile_path: profile_path,
       tags: state.tags,
       generations: generations
     })}
  end

  defp to_garden_seed_generation(%Nix.Profile.Generation{} = gen, current_path) do
    GardenSeedGeneration.cast!(%{
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

      iex> Garden.Profile.extract_generation_number("/nix/var/nix/profiles/system-42-link")
      42

      iex> Garden.Profile.extract_generation_number("/nix/var/nix/profiles/system")
      nil
  """
  def extract_generation_number(link) do
    case Regex.run(~r/-(\d+)-link$/, link) do
      [_, num] -> String.to_integer(num)
      nil -> nil
    end
  end
end
