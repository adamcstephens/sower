defmodule SowerAgent.ProfileTest do
  use ExUnit.Case, async: true

  alias Nix.Profile.Generation
  alias SowerAgent.Profile
  alias SowerClient.Orchestration.{AgentSeedGeneration, AgentSeedProfile}

  describe "do_collect_profile/2" do
    test "collects profile with generations from module state" do
      profile_path = "/nix/var/nix/profiles/system"
      current_path = "/nix/store/abc123-nixos-system"
      created = ~U[2024-01-15 10:00:00Z]

      generations = [
        %Generation{
          path: "/nix/store/abc123-nixos-system",
          link: "/nix/var/nix/profiles/system-42-link",
          created: created
        },
        %Generation{
          path: "/nix/store/def456-nixos-system",
          link: "/nix/var/nix/profiles/system-41-link",
          created: ~U[2024-01-14 09:00:00Z]
        }
      ]

      mock_module =
        mock_profile_module(%{
          current: hd(generations),
          current_path: current_path,
          profiles: generations,
          tags: %{hostname: "test-host"}
        })

      assert {:ok, %AgentSeedProfile{} = result} =
               Profile.do_collect_profile(mock_module, profile_path)

      assert result.profile_path == profile_path
      assert result.tags == %{hostname: "test-host"}
      assert length(result.generations) == 2

      [gen1, gen2] = result.generations
      assert %AgentSeedGeneration{} = gen1
      assert gen1.path == "/nix/store/abc123-nixos-system"
      assert gen1.link == "/nix/var/nix/profiles/system-42-link"
      assert gen1.generation_number == 42
      assert gen1.is_current == true

      assert gen2.path == "/nix/store/def456-nixos-system"
      assert gen2.generation_number == 41
      assert gen2.is_current == false
    end

    test "prepends current generation when not in profiles list" do
      profile_path = "/nix/var/nix/profiles/system"
      current_path = "/nix/store/current-nixos-system"

      current_gen = %Generation{
        path: current_path,
        link: "/nix/var/nix/profiles/system",
        created: ~U[2024-01-16 12:00:00Z]
      }

      older_gen = %Generation{
        path: "/nix/store/old-nixos-system",
        link: "/nix/var/nix/profiles/system-40-link",
        created: ~U[2024-01-10 08:00:00Z]
      }

      mock_module =
        mock_profile_module(%{
          current: current_gen,
          current_path: current_path,
          profiles: [older_gen],
          tags: %{}
        })

      assert {:ok, %AgentSeedProfile{} = result} =
               Profile.do_collect_profile(mock_module, profile_path)

      assert length(result.generations) == 2

      [first_gen | _] = result.generations
      assert first_gen.path == current_path
      assert first_gen.is_current == true
    end

    test "does not duplicate current generation when already in profiles" do
      profile_path = "/nix/var/nix/profiles/system"
      current_path = "/nix/store/abc123-nixos-system"

      current_gen = %Generation{
        path: current_path,
        link: "/nix/var/nix/profiles/system-42-link",
        created: ~U[2024-01-15 10:00:00Z]
      }

      mock_module =
        mock_profile_module(%{
          current: current_gen,
          current_path: current_path,
          profiles: [current_gen],
          tags: %{}
        })

      assert {:ok, %AgentSeedProfile{} = result} =
               Profile.do_collect_profile(mock_module, profile_path)

      assert length(result.generations) == 1
      assert hd(result.generations).path == current_path
    end

    test "handles empty tags" do
      profile_path = "/nix/var/nix/profiles/home-manager"
      current_path = "/nix/store/hm-gen"

      gen = %Generation{
        path: current_path,
        link: "/nix/var/nix/profiles/home-manager-5-link",
        created: ~U[2024-01-15 10:00:00Z]
      }

      mock_module =
        mock_profile_module(%{
          current: gen,
          current_path: current_path,
          profiles: [gen],
          tags: %{}
        })

      assert {:ok, %AgentSeedProfile{} = result} =
               Profile.do_collect_profile(mock_module, profile_path)

      assert result.tags == %{}
    end
  end

  describe "extract_generation_number/1" do
    test "extracts generation number from standard link path" do
      assert Profile.extract_generation_number("/nix/var/nix/profiles/system-42-link") == 42
      assert Profile.extract_generation_number("/nix/var/nix/profiles/system-1-link") == 1
      assert Profile.extract_generation_number("/nix/var/nix/profiles/system-999-link") == 999
    end

    test "extracts generation number from home-manager link" do
      assert Profile.extract_generation_number(
               "/home/user/.local/state/nix/profiles/home-manager-15-link"
             ) == 15
    end

    test "returns nil for profile path without generation number" do
      assert Profile.extract_generation_number("/nix/var/nix/profiles/system") == nil
      assert Profile.extract_generation_number("/nix/var/nix/profiles/home-manager") == nil
    end

    test "returns nil for non-matching patterns" do
      assert Profile.extract_generation_number("/nix/store/abc123-package") == nil
      assert Profile.extract_generation_number("system-42") == nil
    end
  end

  defp mock_profile_module(state) do
    # Create a module at runtime that implements get_state/0
    module_name = :"MockProfile#{:erlang.unique_integer([:positive])}"

    Module.create(
      module_name,
      quote do
        def get_state() do
          %{
            current: unquote(Macro.escape(state.current)),
            current_path: unquote(state.current_path),
            profiles: unquote(Macro.escape(state.profiles)),
            tags: unquote(Macro.escape(state.tags))
          }
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module_name
  end
end
