defmodule Garden.ManagedProfilesTest do
  use ExUnit.Case, async: false

  alias Garden.ManagedProfiles
  alias SowerClient.Orchestration.{ProfileRetention, Subscription}

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    profiles = Path.join(directory, "profiles")
    File.mkdir_p!(profiles)

    config = %SowerClient.Config{
      state_directory: directory,
      managed_profiles_directory: profiles,
      nix_state_directory: System.get_env("NIX_STATE_DIR", "/nix/var/nix")
    }

    seeds =
      for number <- 1..4 do
        source = Path.join(directory, "artifact-#{number}")
        File.mkdir_p!(source)
        File.write!(Path.join(source, "content"), "managed-profile-fixture-#{number}")
        {output, 0} = System.cmd("nix-store", ["--add", source], stderr_to_stdout: true)

        %SowerClient.Seed{
          sid: "seed-#{number}",
          name: "tool",
          seed_type: "package",
          artifact: String.trim(output)
        }
      end

    subscription = %Subscription{
      sid: "subscription-one",
      name: "one",
      seed_name: "tool",
      seed_type: "package"
    }

    %{opts: [config: config], subscription: subscription, seeds: seeds}
  end

  test "same artifact has independent named roots and repeated activation is idempotent",
       context do
    %{opts: opts, subscription: subscription, seeds: [seed | _]} = context
    other = %{subscription | sid: "subscription-two", name: "two"}

    assert {:ok, first} = ManagedProfiles.deploy(subscription, seed, :activate, opts)
    assert {:ok, second} = ManagedProfiles.deploy(other, seed, :activate, opts)
    assert {:ok, repeated} = ManagedProfiles.deploy(subscription, seed, :activate, opts)
    assert repeated.generations == first.generations
    assert first.profile_path != second.profile_path
    assert selected_artifact(first) == seed.artifact
    assert selected_artifact(second) == seed.artifact
    assert hd(first.generations).generation_path != hd(second.generations).generation_path

    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, opts)
    assert selected_artifact(second) == seed.artifact
    assert File.exists?(hd(second.generations).generation_path)
    assert File.exists?(seed.artifact)
  end

  test "replayed uninstall cannot remove a replacement subscription with the same profile name",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    old_opts = Keyword.put(opts, :expected_subscription_sid, subscription.sid)
    assert {:ok, _} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, old_opts)
    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, old_opts)

    replacement = %{subscription | sid: "replacement-subscription"}
    assert {:ok, installed} = ManagedProfiles.deploy(replacement, second, :activate, opts)
    assert {:error, :ownership_conflict} = ManagedProfiles.uninstall(subscription.name, old_opts)
    assert {:ok, preserved} = ManagedProfiles.inspect(subscription.name, opts)
    assert preserved == installed
    assert selected_artifact(preserved) == second.artifact
    assert File.read_link!(hd(preserved.generations).generation_path) == second.artifact

    assert {:ok, :uninstalled} =
             ManagedProfiles.uninstall(
               subscription.name,
               Keyword.put(opts, :expected_subscription_sid, replacement.sid)
             )
  end

  test "omitted retention preserves old local generations and rollback reuses native generation",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    [generation] = original.generations
    assert {:ok, _} = ManagedProfiles.deploy(subscription, second, :activate, opts)

    assert {:ok, retained} =
             ManagedProfiles.retain(subscription.name, at(opts, ~U[2040-01-01 00:00:00Z]))

    assert length(retained.generations) == 2

    assert {:ok, rolled_back} =
             ManagedProfiles.rollback(subscription.name, generation.generation_id, opts)

    assert selected_artifact(rolled_back) == first.artifact

    assert Enum.find(rolled_back.generations, & &1.is_current).generation_number ==
             generation.generation_number

    assert length(Path.wildcard(rolled_back.profile_path <> "-*-link")) == 2
  end

  test "staging and restaging retained artifacts protect them until explicit discard", context do
    %{opts: opts, subscription: subscription, seeds: [first, second, third | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    [generation] = original.generations
    assert {:ok, _} = ManagedProfiles.deploy(subscription, second, :activate, opts)
    subscription = %{subscription | retention: %ProfileRetention{keep_generations: 0}}

    assert {:ok, restaged} = ManagedProfiles.stage(subscription, first, opts)
    assert selected_artifact(restaged) == second.artifact

    assert Enum.find(restaged.generations, &(&1.generation_id == generation.generation_id)).is_staged

    assert {:ok, staged} = ManagedProfiles.stage(subscription, third, opts)
    assert length(staged.generations) == 3

    assert {:ok, retained} =
             ManagedProfiles.retain(subscription.name, at(opts, ~U[2040-01-01 00:00:00Z]))

    assert length(retained.generations) == 3

    assert {:ok, discarded} =
             ManagedProfiles.discard(subscription.name, generation.generation_id, opts)

    refute File.exists?(generation.generation_path)
    refute File.exists?(generation.link)
    assert selected_artifact(discarded) == second.artifact

    assert {:error, :generation_not_found} =
             ManagedProfiles.select(subscription.name, generation.generation_id, opts)

    current = Enum.find(discarded.generations, & &1.is_current)

    assert {:error, :generation_protected} =
             ManagedProfiles.discard(subscription.name, current.generation_id, opts)
  end

  test "pins prevent pruning and block uninstall until explicitly released", context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    [generation] = original.generations
    assert {:ok, _} = ManagedProfiles.pin(subscription.name, generation.generation_id, opts)
    subscription = %{subscription | retention: %ProfileRetention{keep_generations: 0}}
    assert {:ok, installed} = ManagedProfiles.deploy(subscription, second, :activate, opts)
    assert length(installed.generations) == 2
    assert {:error, :pinned_generations} = ManagedProfiles.uninstall(subscription.name, opts)
    assert {:ok, blocked} = ManagedProfiles.inspect(subscription.name, opts)
    assert blocked.lifecycle_status == "uninstall_blocked"
    assert selected_artifact(blocked) == second.artifact
    assert {:error, :uninstall_pending} = ManagedProfiles.stage(subscription, first, opts)
    assert {:ok, _} = ManagedProfiles.unpin(subscription.name, generation.generation_id, opts)
    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, opts)
    assert {:error, :enoent} = ManagedProfiles.inspect(subscription.name, opts)
    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, opts)
  end

  test "retention keeps the union of local count and age windows independently of selection",
       context do
    %{opts: opts, subscription: subscription, seeds: seeds} = context

    dates = [
      ~U[2025-01-01 00:00:00Z],
      ~U[2025-01-02 00:00:00Z],
      ~U[2025-01-09 00:00:00Z],
      ~U[2025-01-10 00:00:00Z]
    ]

    profiles =
      for {seed, date} <- Enum.zip(seeds, dates) do
        assert {:ok, profile} =
                 ManagedProfiles.deploy(subscription, seed, :activate, at(opts, date))

        profile
      end

    [oldest] = hd(profiles).generations
    assert {:ok, _} = ManagedProfiles.rollback(subscription.name, oldest.generation_id, opts)

    subscription = %{
      subscription
      | retention: %ProfileRetention{keep_generations: 1, keep_days: 2}
    }

    assert :ok = ManagedProfiles.sync_subscriptions([subscription], opts)

    assert {:ok, retained} =
             ManagedProfiles.retain(subscription.name, at(opts, ~U[2025-01-10 12:00:00Z]))

    assert Enum.map(retained.generations, & &1.path) ==
             Enum.map([Enum.at(seeds, 0), Enum.at(seeds, 2), Enum.at(seeds, 3)], & &1.artifact)

    assert selected_artifact(retained) == hd(seeds).artifact
    assert hd(retained.generations).created == hd(dates)

    assert {:ok, later} =
             ManagedProfiles.retain(subscription.name, at(opts, ~U[2025-02-01 00:00:00Z]))

    assert Enum.map(later.generations, & &1.path) == [
             hd(seeds).artifact,
             List.last(seeds).artifact
           ]
  end

  test "unchanged local retention preserves server override until the declaration changes",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second, third, fourth]} = context
    declared = %{subscription | sid: nil, retention: %ProfileRetention{keep_generations: 3}}
    config = %{opts[:config] | subscriptions: [declared]}
    opts = Keyword.put(opts, :config, config)
    subscription = %{subscription | retention: declared.retention}

    for {seed, day} <- Enum.zip([first, second, third], 1..3) do
      datetime = DateTime.add(~U[2025-01-01 00:00:00Z], day * 86_400)
      assert {:ok, _} = ManagedProfiles.deploy(subscription, seed, :activate, at(opts, datetime))
    end

    server = %{subscription | retention: %ProfileRetention{keep_generations: 1}}
    assert :ok = ManagedProfiles.sync_subscriptions([server], opts)
    assert :ok = ManagedProfiles.sync_local_subscriptions(opts)
    assert :ok = ManagedProfiles.retain_all(at(opts, ~U[2025-02-01 00:00:00Z]))
    assert {:ok, overridden} = ManagedProfiles.inspect(subscription.name, opts)
    assert overridden.retention.keep_generations == 1
    assert Enum.map(overridden.generations, & &1.path) == [third.artifact]

    changed = %{declared | retention: %ProfileRetention{keep_generations: 2}}
    opts = Keyword.put(opts, :config, %{config | subscriptions: [changed]})
    assert :ok = ManagedProfiles.retain_all(opts)
    assert {:ok, updated} = ManagedProfiles.inspect(subscription.name, opts)
    assert updated.retention.keep_generations == 2
    subscription = %{subscription | retention: changed.retention}
    assert {:ok, _} = ManagedProfiles.deploy(subscription, fourth, :activate, opts)
    assert :ok = ManagedProfiles.retain_all(at(opts, ~U[2040-01-01 00:00:00Z]))
    assert {:ok, retained} = ManagedProfiles.inspect(subscription.name, opts)
    assert Enum.map(retained.generations, & &1.path) == [third.artifact, fourth.artifact]
  end

  test "corrupt ownership cannot be overwritten by stage or uninstall", context do
    %{opts: opts, subscription: subscription, seeds: [seed | _]} = context
    assert {:ok, profile} = ManagedProfiles.deploy(subscription, seed, :activate, opts)
    ledger = ledger_path(subscription.name, opts)
    File.write!(ledger, "not-json")

    assert {:error, _} = ManagedProfiles.inspect(subscription.name, opts)
    assert {:error, _} = ManagedProfiles.list(opts)
    assert {:error, _} = ManagedProfiles.stage(subscription, seed, opts)
    assert {:error, _} = ManagedProfiles.uninstall(subscription.name, opts)
    assert File.read!(ledger) == "not-json"
    assert selected_artifact(profile) == seed.artifact
  end

  test "unowned publication directories and replaced generation roots are never deleted",
       context do
    %{opts: opts, subscription: subscription, seeds: [seed, other | _]} = context
    directory = Path.join(opts[:config].managed_profiles_directory, subscription.name)
    File.mkdir_p!(directory)
    sentinel = Path.join(directory, "foreign")
    File.write!(sentinel, "keep")
    assert {:error, :unowned_profile_directory} = ManagedProfiles.stage(subscription, seed, opts)
    assert File.read!(sentinel) == "keep"
    File.rm!(sentinel)
    File.rmdir!(directory)

    assert {:ok, staged} = ManagedProfiles.stage(subscription, seed, opts)
    [generation] = staged.generations
    File.rm!(generation.generation_path)
    File.ln_s!(other.artifact, generation.generation_path)

    assert {:error, :ownership_conflict} =
             ManagedProfiles.discard(subscription.name, generation.generation_id, opts)

    assert File.read_link!(generation.generation_path) == other.artifact
    assert File.exists?(other.artifact)
  end

  test "failed realization recovers without changing the selected generation", context do
    %{opts: opts, subscription: subscription, seeds: [seed | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, seed, :activate, opts)

    missing = %{
      seed
      | sid: "missing",
        artifact: "/nix/store/00000000000000000000000000000000-missing"
    }

    assert {:error, {:nix_failed, _, _}} = ManagedProfiles.stage(subscription, missing, opts)
    assert {:ok, recovered} = ManagedProfiles.inspect(subscription.name, opts)
    assert recovered.generations == original.generations
    assert selected_artifact(recovered) == seed.artifact
  end

  test "interrupted native selection removes only newly created roots and preserves previous selection",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    [previous] = original.generations
    assert {:ok, staged} = ManagedProfiles.stage(subscription, second, opts)
    target = Enum.find(staged.generations, & &1.is_staged)
    preexisting = staged.profile_path <> "-9-link.tmp-123-456"
    File.ln_s!(first.artifact, preexisting)
    native_before = Path.wildcard(staged.profile_path <> "-*-link") ++ [preexisting]
    ledger = ledger_path(subscription.name, opts)
    data = Jason.decode!(File.read!(ledger))

    File.write!(
      ledger,
      Jason.encode!(
        Map.merge(data, %{
          "operation" => "select",
          "target" => target.generation_id,
          "previous" => previous.generation_id,
          "native_before" => native_before
        })
      )
    )

    interrupted_root = staged.profile_path <> "-2-link"
    File.ln_s!(second.artifact, interrupted_root)
    interrupted_temporary = interrupted_root <> ".tmp-123-456"
    interrupted_pointer = Path.join(Path.dirname(staged.profile_path), ".0_profile")
    File.ln_s!(second.artifact, interrupted_temporary)
    File.ln_s!(Path.basename(interrupted_root), interrupted_pointer)

    assert {:ok, recovered} = ManagedProfiles.inspect(subscription.name, opts)
    assert selected_artifact(recovered) == first.artifact
    refute File.exists?(interrupted_root)
    assert {:error, :enoent} = File.lstat(interrupted_temporary)
    assert {:error, :enoent} = File.lstat(interrupted_pointer)
    assert File.read_link!(preexisting) == first.artifact
    assert File.exists?(target.generation_path)
    assert File.exists?(previous.link)
    assert {:ok, selected} = ManagedProfiles.select(subscription.name, target.generation_id, opts)
    assert selected_artifact(selected) == second.artifact
  end

  test "interrupted staging cleans its temporary root without changing selection", context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    assert {:ok, staged} = ManagedProfiles.stage(subscription, second, opts)
    target = Enum.find(staged.generations, & &1.is_staged)
    ledger = ledger_path(subscription.name, opts)
    data = Jason.decode!(File.read!(ledger))

    File.write!(
      ledger,
      Jason.encode!(Map.merge(data, %{"operation" => "stage", "target" => target.generation_id}))
    )

    File.rm!(target.generation_path)
    temporary = target.generation_path <> ".tmp-123-456"
    File.ln_s!(second.artifact, temporary)

    assert {:ok, recovered} = ManagedProfiles.inspect(subscription.name, opts)
    assert recovered.generations == original.generations
    assert selected_artifact(recovered) == first.artifact
    assert {:error, :enoent} = File.lstat(temporary)
  end

  test "interrupted staging refuses to unlink a temporary root targeting another artifact",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    assert {:ok, staged} = ManagedProfiles.stage(subscription, second, opts)
    target = Enum.find(staged.generations, & &1.is_staged)
    ledger = ledger_path(subscription.name, opts)
    data = Jason.decode!(File.read!(ledger))

    File.write!(
      ledger,
      Jason.encode!(Map.merge(data, %{"operation" => "stage", "target" => target.generation_id}))
    )

    File.rm!(target.generation_path)
    temporary = target.generation_path <> ".tmp-123-456"
    File.ln_s!(first.artifact, temporary)

    assert {:error, :ownership_conflict} = ManagedProfiles.inspect(subscription.name, opts)
    assert File.read_link!(temporary) == first.artifact
    assert selected_artifact(original) == first.artifact
  end

  test "uncertain cleanup blocks the current boot but replays the preserved journal after reboot",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, original} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    assert {:ok, staged} = ManagedProfiles.stage(subscription, second, opts)
    target = Enum.find(staged.generations, & &1.is_staged)
    ledger = ledger_path(subscription.name, opts)
    boot_id_file = System.get_env("VM_MANAGER_BOOT_ID_FILE", "/proc/sys/kernel/random/boot_id")
    boot_id = File.read!(boot_id_file) |> String.trim()
    data = Jason.decode!(File.read!(ledger))

    blocked =
      Map.merge(data, %{
        "operation" => "stage",
        "target" => target.generation_id,
        "blocked_boot_id" => boot_id,
        "profile" =>
          Map.put(data["profile"], "last_error", "Native process cleanup is unconfirmed")
      })

    File.write!(ledger, Jason.encode!(blocked))
    File.rm!(target.generation_path)
    temporary = target.generation_path <> ".tmp-123-456"
    File.ln_s!(second.artifact, temporary)

    assert {:error, :process_cleanup_unconfirmed} =
             ManagedProfiles.inspect(subscription.name, opts)

    assert {:error, :process_cleanup_unconfirmed} =
             ManagedProfiles.uninstall(subscription.name, opts)

    assert File.read_link!(temporary) == second.artifact
    assert selected_artifact(original) == first.artifact
    assert Jason.decode!(File.read!(ledger)) == blocked

    File.write!(ledger, Jason.encode!(%{blocked | "blocked_boot_id" => "previous-boot"}))
    assert {:ok, recovered} = ManagedProfiles.inspect(subscription.name, opts)
    assert recovered.generations == original.generations
    assert recovered.last_error == nil
    assert selected_artifact(recovered) == first.artifact
    assert {:error, :enoent} = File.lstat(temporary)
    assert {:error, :enoent} = File.lstat(target.generation_path)
    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, opts)
  end

  test "boot identity uses the service credential with explicit file options taking precedence",
       context do
    %{opts: opts, subscription: subscription, seeds: [seed | _], tmp_dir: directory} = context
    credential = Path.join(directory, "boot-id-credential")
    override = Path.join(directory, "boot-id-override")
    File.write!(credential, "credential-boot\n")
    File.write!(override, "override-boot\n")
    previous = System.get_env("VM_MANAGER_BOOT_ID_FILE")
    System.put_env("VM_MANAGER_BOOT_ID_FILE", credential)

    on_exit(fn ->
      if previous do
        System.put_env("VM_MANAGER_BOOT_ID_FILE", previous)
      else
        System.delete_env("VM_MANAGER_BOOT_ID_FILE")
      end
    end)

    assert {:ok, staged} = ManagedProfiles.stage(subscription, seed, opts)
    [target] = staged.generations
    ledger = ledger_path(subscription.name, opts)
    data = Jason.decode!(File.read!(ledger))

    blocked =
      Map.merge(data, %{
        "operation" => "stage",
        "target" => target.generation_id,
        "blocked_boot_id" => "credential-boot"
      })

    File.write!(ledger, Jason.encode!(blocked))

    assert {:error, :process_cleanup_unconfirmed} =
             ManagedProfiles.inspect(subscription.name, opts)

    assert File.read_link!(target.generation_path) == seed.artifact

    assert {:ok, recovered} =
             ManagedProfiles.inspect(
               subscription.name,
               Keyword.put(opts, :boot_id_file, override)
             )

    assert recovered.generations == staged.generations
    assert File.read_link!(target.generation_path) == seed.artifact
    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, opts)
  end

  test "activation excludes same-profile retention and uninstall without blocking another profile",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, _} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    parent = self()

    activation =
      Task.async(fn ->
        ManagedProfiles.deploy(
          subscription,
          second,
          :activate,
          Keyword.put(opts, :on_output, barrier(parent))
        )
      end)

    assert_receive {:native_output, worker}, 5_000
    retention = Task.async(fn -> ManagedProfiles.retain(subscription.name, opts) end)
    removal = Task.async(fn -> ManagedProfiles.uninstall(subscription.name, opts) end)
    other = %{subscription | name: "two", sid: "subscription-two"}
    assert {:ok, _} = ManagedProfiles.stage(other, first, opts)
    assert Task.yield(retention, 50) == nil
    assert Task.yield(removal, 50) == nil
    send(worker, :continue)
    assert {:ok, activated} = Task.await(activation, 5_000)
    assert Enum.find(activated.generations, & &1.is_current).path == second.artifact
    assert Task.await(retention, 5_000) in [{:error, :enoent}, {:ok, activated}]
    assert {:ok, :uninstalled} = Task.await(removal, 5_000)
    refute File.exists?(activated.profile_path)
    assert {:ok, _} = ManagedProfiles.inspect(other.name, opts)
  end

  test "caller death during realization does not release the operation before activation finishes",
       context do
    %{opts: opts, subscription: subscription, seeds: [first, second | _]} = context
    assert {:ok, _} = ManagedProfiles.deploy(subscription, first, :activate, opts)
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        ManagedProfiles.deploy(
          subscription,
          second,
          :activate,
          Keyword.put(opts, :on_output, barrier(parent))
        )
      end)

    assert_receive {:native_output, operation_worker}, 5_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    inspection = Task.async(fn -> ManagedProfiles.inspect(subscription.name, opts) end)
    assert Task.yield(inspection, 50) == nil
    send(operation_worker, :continue)
    assert {:ok, recovered} = Task.await(inspection, 5_000)
    assert selected_artifact(recovered) == second.artifact
    assert Enum.find(recovered.generations, & &1.is_current).path == second.artifact
    assert {:ok, :uninstalled} = ManagedProfiles.uninstall(subscription.name, opts)
  end

  defp barrier(parent) do
    calls = :atomics.new(1, [])

    fn _output ->
      if :atomics.add_get(calls, 1, 1) == 1 do
        send(parent, {:native_output, self()})

        receive do
          :continue -> :ok
        end
      end
    end
  end

  defp selected_artifact(profile) do
    profile.profile_path
    |> File.read_link!()
    |> Path.expand(Path.dirname(profile.profile_path))
    |> File.read_link!()
  end

  defp at(opts, datetime), do: Keyword.put(opts, :now, fn -> datetime end)

  defp ledger_path(name, opts),
    do: Path.join([opts[:config].state_directory, "managed-profiles", name <> ".json"])
end
