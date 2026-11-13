defmodule Garden.ManagedProfiles do
  @moduledoc """
  Owns named package and devshell profiles, their durable roots and local retention.

  Every mutation and observation is serialized per profile. A private atomic journal
  records ownership before Nix creates roots; interrupted operations are reconciled
  before subsequent access. Published paths never expose Garden's private state.
  Removing a root does not run garbage collection or stop external consumers.
  """

  use TypedStruct
  import Kernel, except: [inspect: 1, inspect: 2]

  alias SowerClient.Orchestration.{GardenSeedGeneration, GardenSeedProfile, Subscription}

  typedstruct module: State do
    @moduledoc "Private durable ownership and interrupted-operation journal for one profile."
    field :profile, GardenSeedProfile.t(), enforce: true
    field :operation, String.t()
    field :target, String.t()
    field :previous, String.t()
    field :native_before, [String.t()], default: []
    field :declared_retention, SowerClient.Orchestration.ProfileRetention.t()
    field :blocked_boot_id, String.t()
  end

  @managed_types ["package", "devshell"]

  def managed?(type), do: type in @managed_types

  def supported? do
    :os.type() == {:unix, :linux} and
      Enum.all?(["nix-store", "nix-env", "sower"], &System.find_executable/1)
  end

  def list(opts \\ []) do
    case File.ls(ledger_directory(opts)) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn file, {:ok, profiles} ->
          case inspect(String.trim_trailing(file, ".json"), opts) do
            {:ok, profile} -> {:cont, {:ok, [profile | profiles]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, profiles} -> {:ok, Enum.reverse(profiles)}
          error -> error
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def inspect(name, opts \\ []) do
    locked(name, opts, fn ->
      with {:ok, state} <- load(name, opts),
           {:ok, state} <- recover(state, opts) do
        {:ok, state.profile}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def stage(%Subscription{} = subscription, seed, opts \\ []),
    do: deploy(subscription, seed, :stage, opts)

  def deploy(%Subscription{} = subscription, seed, action, opts \\ [])
      when action in [:stage, :activate] do
    locked(subscription.name, opts, fn ->
      with :ok <- validate_binding(subscription, seed),
           {:ok, state} <- load_or_create(subscription, opts),
           {:ok, state} <- recover(state, opts),
           :ok <- accepting_updates(state),
           state = %{state | profile: %{state.profile | retention: subscription.retention}},
           {:ok, state, generation} <- realize(state, seed, opts),
           {:ok, state} <- maybe_select(state, generation, action, opts),
           {:ok, state} <- retain_state(state, opts) do
        {:ok, state.profile}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def select(name, generation_id, opts \\ []) do
    mutate(name, opts, fn state ->
      with :ok <- accepting_updates(state),
           {:ok, generation} <- generation(state, generation_id),
           {:ok, state} <- select_generation(state, generation, opts),
           {:ok, state} <- retain_state(state, opts) do
        {:ok, state}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def rollback(name, generation_id, opts \\ []), do: select(name, generation_id, opts)
  def pin(name, generation_id, opts \\ []), do: set_pin(name, generation_id, true, opts)
  def unpin(name, generation_id, opts \\ []), do: set_pin(name, generation_id, false, opts)

  def discard(name, generation_id, opts \\ []) do
    mutate(name, opts, fn state ->
      with {:ok, generation} <- generation(state, generation_id),
           false <- generation.is_current or generation.pinned,
           true <- generation.is_staged,
           {:ok, state} <- remove_generation(state, generation, opts) do
        {:ok, state}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :generation_protected}
      end
    end)
  end

  def uninstall(name, opts \\ []) do
    locked(name, opts, fn ->
      case load(name, opts) do
        {:ok, state} ->
          with true <-
                 not Keyword.has_key?(opts, :expected_subscription_sid) or
                   state.profile.subscription_sid == Keyword.get(opts, :expected_subscription_sid),
               {:ok, state} <- recover(state, opts) do
            if Keyword.get(opts, :preview, false),
              do: {:ok, state.profile},
              else: uninstall_state(state, opts)
          else
            false -> {:error, :ownership_conflict}
            {:error, reason} -> {:error, reason}
          end

        {:error, :enoent} ->
          {:ok, :uninstalled}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def retain(name, opts \\ []), do: mutate(name, opts, &retain_state(&1, opts))

  def retain_all(opts \\ []) do
    with :ok <- sync_local_subscriptions(opts),
         {:ok, profiles} <- list(opts) do
      Enum.reduce_while(profiles, :ok, fn profile, :ok ->
        case retain(profile.name, opts) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def sync_local_subscriptions(opts \\ []) do
    sync_subscriptions(config(opts).subscriptions || [], Keyword.put(opts, :local_policy, true))
  end

  def sync_subscriptions(subscriptions, opts \\ []) do
    subscriptions
    |> Enum.filter(&managed?(&1.seed_type))
    |> Enum.reduce_while(:ok, fn subscription, :ok ->
      result =
        mutate(subscription.name, opts, fn state ->
          if state.profile.seed_type == subscription.seed_type and
               (state.profile.subscription_sid == subscription.sid or
                  Keyword.get(opts, :local_policy, false)) do
            cond do
              Keyword.get(opts, :local_policy, false) and
                  state.declared_retention == subscription.retention ->
                {:ok, state}

              Keyword.get(opts, :local_policy, false) ->
                save(
                  %{
                    state
                    | declared_retention: subscription.retention,
                      profile: %{state.profile | retention: subscription.retention}
                  },
                  opts
                )

              true ->
                save(
                  %{state | profile: %{state.profile | retention: subscription.retention}},
                  opts
                )
            end
          else
            {:error, :ownership_conflict}
          end
        end)

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp locked(name, opts, fun) do
    cond do
      not supported?() ->
        {:error, :managed_profiles_unsupported}

      is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, name) ->
        caller = self()
        reference = make_ref()

        {:ok, pid} =
          Task.Supervisor.start_child(
            Garden.TaskSupervisor,
            fn ->
              Process.flag(:trap_exit, true)

              result =
                :global.trans({{__MODULE__, ledger_directory(opts), name}, self()}, fun, [node()])

              send(caller, {reference, result})
            end,
            shutdown: :infinity
          )

        monitor = Process.monitor(pid)

        receive do
          {^reference, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            {:error, {:operation_failed, reason}}
        end

      true ->
        {:error, :invalid_profile_name}
    end
  end

  defp mutate(name, opts, fun) do
    locked(name, opts, fn ->
      with {:ok, state} <- load(name, opts),
           {:ok, state} <- recover(state, opts),
           {:ok, state} <- fun.(state) do
        {:ok, state.profile}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp validate_binding(%Subscription{uninstall_pending: true}, _seed),
    do: {:error, :uninstall_pending}

  defp validate_binding(%Subscription{} = subscription, seed) do
    if managed?(seed.seed_type) and subscription.seed_type == seed.seed_type and
         subscription.seed_name == seed.name and is_binary(subscription.sid) and
         Regex.match?(~r/\A\/nix\/store\/[a-z0-9]{32}-[^\/]+\z/, seed.artifact) do
      :ok
    else
      {:error, :invalid_profile_binding}
    end
  end

  defp accepting_updates(%State{} = state) do
    if state.profile.lifecycle_status in ["uninstall_pending", "uninstall_blocked"],
      do: {:error, :uninstall_pending},
      else: :ok
  end

  defp load_or_create(%Subscription{} = subscription, opts) do
    case load(subscription.name, opts) do
      {:ok, state} ->
        if state.profile.subscription_sid == subscription.sid and
             state.profile.seed_type == subscription.seed_type,
           do: {:ok, state},
           else: {:error, :ownership_conflict}

      {:error, :enoent} ->
        directory = publication_directory(subscription.name, opts)

        profile =
          GardenSeedProfile.cast!(%{
            name: subscription.name,
            subscription_sid: subscription.sid,
            seed_type: subscription.seed_type,
            managed: true,
            retention: subscription.retention,
            lifecycle_status: "staged",
            profile_path: Path.join(directory, "profile"),
            generations: [],
            tags: %{}
          })

        declaration = Enum.find(config(opts).subscriptions || [], &(&1.name == subscription.name))

        with {:error, :enoent} <- File.lstat(directory),
             :ok <- File.mkdir_p(ledger_directory(opts)),
             :ok <- File.chmod(ledger_directory(opts), 0o700),
             :ok <- sync_directory(config(opts).state_directory),
             {:ok, state} <-
               save(
                 %State{
                   profile: profile,
                   operation: "create",
                   declared_retention: declaration && declaration.retention
                 },
                 opts
               ) do
          recover(state, opts)
        else
          {:ok, _} -> {:error, :unowned_profile_directory}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp realize(%State{} = state, seed, opts) do
    case Enum.find(state.profile.generations, &(&1.path == seed.artifact)) do
      nil ->
        id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        root = Path.join(publication_directory(state.profile.name, opts), "generation-#{id}")

        generation =
          GardenSeedGeneration.cast!(%{
            generation_id: id,
            seed_sid: seed.sid,
            path: seed.artifact,
            link: root,
            generation_path: root,
            created: DateTime.to_iso8601(now(opts)),
            generation_number: nil,
            is_current: false,
            is_staged: true,
            pinned: false
          })

        state = %{
          state
          | profile: %{state.profile | generations: state.profile.generations ++ [generation]},
            operation: "stage",
            target: id
        }

        with {:ok, state} <- save(state, opts),
             :ok <-
               command(
                 state,
                 "nix-store",
                 ["--realize", seed.artifact, "--add-root", root, "--indirect"],
                 opts
               ),
             {:ok, state} <- clear_journal(state, opts) do
          {:ok, state, generation}
        else
          {:error, reason} -> {:error, reason}
        end

      generation ->
        {:ok, state, generation}
    end
  end

  defp maybe_select(%State{} = state, %GardenSeedGeneration{} = generation, :stage, opts) do
    generations =
      Enum.map(state.profile.generations, fn gen ->
        if gen.generation_id == generation.generation_id and not gen.is_current,
          do: %{gen | is_staged: true},
          else: gen
      end)

    save(%{state | profile: %{state.profile | generations: generations}}, opts)
  end

  defp maybe_select(state, generation, :activate, opts),
    do: select_generation(state, generation, opts)

  defp select_generation(%State{} = state, %GardenSeedGeneration{is_current: true}, opts),
    do: save(state, opts)

  defp select_generation(%State{} = state, %GardenSeedGeneration{} = generation, opts) do
    previous = Enum.find(state.profile.generations, & &1.is_current)

    args =
      if generation.generation_number do
        [
          "--profile",
          state.profile.profile_path,
          "--switch-generation",
          to_string(generation.generation_number)
        ]
      else
        ["--profile", state.profile.profile_path, "--set", generation.path]
      end

    with {:ok, before} <- native_links(state),
         journal = %{
           state
           | operation: "select",
             target: generation.generation_id,
             previous: previous && previous.generation_id,
             native_before: before
         },
         {:ok, state} <- save(journal, opts),
         :ok <- command(state, "nix-env", args, opts),
         {:ok, state} <- finish_selection(state, opts) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_selection(%State{} = state, opts, recovering \\ false) do
    with {:ok, generation} <- generation(state, state.target),
         {:ok, link} <- File.read_link(state.profile.profile_path),
         path = Path.expand(link, Path.dirname(state.profile.profile_path)),
         [_, number] <- Regex.run(~r/\Aprofile-([0-9]+)-link\z/, Path.basename(path)),
         true <- Path.dirname(path) == publication_directory(state.profile.name, opts),
         {:ok, artifact} <- File.read_link(path),
         true <- artifact == generation.path,
         :ok <-
           if(recovering,
             do:
               command(
                 state,
                 "nix-store",
                 ["--realize", artifact, "--add-root", path, "--indirect"],
                 opts
               ),
             else: :ok
           ),
         :ok <- cleanup_native_links(state, :temporary) do
      generations =
        Enum.map(state.profile.generations, fn gen ->
          if gen.generation_id == state.target do
            %{
              gen
              | is_current: true,
                is_staged: false,
                generation_number: String.to_integer(number),
                link: path
            }
          else
            %{gen | is_current: false}
          end
        end)

      clear_journal(
        %{
          state
          | profile: %{state.profile | generations: generations, lifecycle_status: "installed"}
        },
        opts
      )
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_native_selection}
    end
  end

  defp set_pin(name, id, pinned, opts) do
    mutate(name, opts, fn state ->
      with {:ok, generation} <- generation(state, id) do
        generations =
          Enum.map(state.profile.generations, fn gen ->
            if gen.generation_id == generation.generation_id,
              do: %{gen | pinned: pinned},
              else: gen
          end)

        save(%{state | profile: %{state.profile | generations: generations}}, opts)
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp retain_state(%State{profile: %{retention: nil}} = state, opts), do: save(state, opts)

  defp retain_state(%State{} = state, opts) do
    policy = state.profile.retention

    newest =
      state.profile.generations
      |> Enum.sort_by(& &1.created, {:desc, DateTime})
      |> Enum.take(policy.keep_generations || 0)
      |> MapSet.new(& &1.generation_id)

    cutoff = DateTime.add(now(opts), -(policy.keep_days || 0) * 86_400)

    eligible =
      Enum.filter(state.profile.generations, fn gen ->
        created = gen.created

        not gen.is_current and not gen.pinned and not gen.is_staged and
          not MapSet.member?(newest, gen.generation_id) and
          DateTime.compare(created, cutoff) == :lt
      end)

    Enum.reduce_while(eligible, {:ok, state}, fn gen, {:ok, state} ->
      case remove_generation(state, gen, opts) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_generation(%State{} = state, %GardenSeedGeneration{} = generation, opts) do
    with {:ok, state} <-
           save(%{state | operation: "remove", target: generation.generation_id}, opts),
         :ok <- remove_roots(state, generation, opts) do
      generations =
        Enum.reject(state.profile.generations, &(&1.generation_id == generation.generation_id))

      clear_journal(%{state | profile: %{state.profile | generations: generations}}, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_roots(%State{} = state, %GardenSeedGeneration{} = generation, opts) do
    root =
      Path.join(
        publication_directory(state.profile.name, opts),
        "generation-#{generation.generation_id}"
      )

    native =
      if generation.generation_number,
        do: state.profile.profile_path <> "-#{generation.generation_number}-link"

    with :ok <- unlink_owned(native, generation.path),
         :ok <- unlink_owned(root, generation.path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp unlink_owned(nil, _artifact), do: :ok

  defp unlink_owned(path, artifact) do
    case File.read_link(path) do
      {:ok, ^artifact} -> File.rm(path)
      {:error, :enoent} -> :ok
      _ -> {:error, :ownership_conflict}
    end
  end

  defp uninstall_state(%State{} = state, opts) do
    status =
      if Enum.any?(state.profile.generations, & &1.pinned),
        do: "uninstall_blocked",
        else: "uninstall_pending"

    with {:ok, state} <-
           save(%{state | profile: %{state.profile | lifecycle_status: status}}, opts),
         false <- status == "uninstall_blocked",
         :ok <- remove_selection(state),
         :ok <- sync_directory(publication_directory(state.profile.name, opts)),
         {:ok, state} <-
           Enum.reduce_while(state.profile.generations, {:ok, state}, fn gen, {:ok, state} ->
             case remove_generation(state, gen, opts) do
               {:ok, state} -> {:cont, {:ok, state}}
               error -> {:halt, error}
             end
           end),
         :ok <- remove_profile_directory(state, opts),
         :ok <- sync_directory(config(opts).managed_profiles_directory),
         :ok <- File.rm(ledger_path(state.profile.name, opts)),
         :ok <- sync_directory(ledger_directory(opts)) do
      {:ok, :uninstalled}
    else
      true -> {:error, :pinned_generations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_selection(%State{} = state) do
    case File.read_link(state.profile.profile_path) do
      {:error, :enoent} ->
        :ok

      {:ok, link} ->
        path = Path.expand(link, Path.dirname(state.profile.profile_path))

        if Enum.any?(state.profile.generations, &(&1.link == path)) do
          File.rm(state.profile.profile_path)
        else
          {:error, :ownership_conflict}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_profile_directory(%State{} = state, opts) do
    lock = state.profile.profile_path <> ".lock"

    with :ok <- remove_lock_file(lock),
         result when result in [:ok, {:error, :enoent}] <-
           File.rmdir(publication_directory(state.profile.name, opts)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_lock_file(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> File.rm(path)
      _ -> {:error, :ownership_conflict}
    end
  end

  defp recover(%State{blocked_boot_id: boot_id} = state, opts) when not is_nil(boot_id) do
    with {:ok, current} <- read_boot_id(opts),
         false <- current == boot_id,
         {:ok, state} <-
           save(
             %{state | blocked_boot_id: nil, profile: %{state.profile | last_error: nil}},
             opts
           ) do
      recover(state, opts)
    else
      true -> {:error, :process_cleanup_unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover(%State{operation: nil} = state, _opts), do: {:ok, state}

  defp recover(%State{operation: "create"} = state, opts) do
    directory = publication_directory(state.profile.name, opts)

    with result when result in [:ok, {:error, :eexist}] <- File.mkdir(directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, 0o755),
         :ok <- sync_directory(config(opts).managed_profiles_directory) do
      clear_journal(state, opts)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :ownership_conflict}
    end
  end

  defp recover(%State{operation: "remove"} = state, opts) do
    with {:ok, gen} <- generation(state, state.target) do
      remove_generation(state, gen, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover(%State{operation: "stage"} = state, opts) do
    with {:ok, gen} <- generation(state, state.target),
         :ok <- cleanup_stage_temps(gen) do
      case File.read_link(gen.generation_path) do
        {:ok, artifact} when artifact == gen.path ->
          with :ok <-
                 command(
                   state,
                   "nix-store",
                   ["--realize", artifact, "--add-root", gen.generation_path, "--indirect"],
                   opts
                 ) do
            clear_journal(state, opts)
          else
            {:error, reason} -> {:error, reason}
          end

        {:error, :enoent} ->
          generations =
            Enum.reject(state.profile.generations, &(&1.generation_id == gen.generation_id))

          clear_journal(%{state | profile: %{state.profile | generations: generations}}, opts)

        _ ->
          {:error, :ownership_conflict}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover(%State{operation: "select"} = state, opts) do
    case finish_selection(state, opts, true) do
      {:ok, state} ->
        {:ok, state}

      {:error, _} ->
        previous = Enum.find(state.profile.generations, &(&1.generation_id == state.previous))

        case File.read_link(state.profile.profile_path) do
          {:error, :enoent} when is_nil(previous) ->
            reconcile_native_links(state, opts)

          {:ok, link} when not is_nil(previous) ->
            if Path.expand(link, Path.dirname(state.profile.profile_path)) == previous.link,
              do: reconcile_native_links(state, opts),
              else: {:error, :selection_recovery_failed}

          _ ->
            {:error, :selection_recovery_failed}
        end
    end
  end

  defp recover(%State{}, _opts), do: {:error, :invalid_journal}

  defp native_links(%State{} = state) do
    directory = Path.dirname(state.profile.profile_path)

    case File.ls(directory) do
      {:ok, names} ->
        paths =
          names
          |> Enum.filter(
            &Regex.match?(
              ~r/\A(?:profile-[0-9]+-link(?:\.tmp-[0-9]+-[0-9]+)?|\.[0-9]+_profile)\z/,
              &1
            )
          )
          |> Enum.map(&Path.join(directory, &1))

        {:ok, paths}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_native_links(%State{} = state, opts) do
    with :ok <- cleanup_native_links(state, :all) do
      clear_journal(state, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_native_links(%State{} = state, mode) do
    with {:ok, existing} <- native_links(state),
         paths =
           Enum.filter(existing -- state.native_before, fn path ->
             mode == :all or not Regex.match?(~r/\Aprofile-[0-9]+-link\z/, Path.basename(path))
           end),
         {:ok, gen} <- generation(state, state.target),
         {:ok, links} <-
           Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, links} ->
             case File.read_link(path) do
               {:ok, target} ->
                 native = Path.expand(target, Path.dirname(path))

                 valid_pointer =
                   Regex.match?(~r/\A\.[0-9]+_profile\z/, Path.basename(path)) and
                     Path.dirname(native) == Path.dirname(path) and
                     Regex.match?(~r/\Aprofile-[0-9]+-link\z/, Path.basename(native)) and
                     (File.read_link(native) == {:ok, gen.path} or
                        (native not in state.native_before and
                           File.read_link(native) == {:error, :enoent}))

                 if target == gen.path or valid_pointer,
                   do: {:cont, {:ok, [{path, target} | links]}},
                   else: {:halt, {:error, :ownership_conflict}}

               {:error, reason} ->
                 {:halt, {:error, reason}}
             end
           end) do
      Enum.reduce_while(links, :ok, fn {path, target}, :ok ->
        case unlink_owned(path, target) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_stage_temps(%GardenSeedGeneration{} = generation) do
    Path.wildcard(generation.generation_path <> ".tmp-*")
    |> Enum.filter(&Regex.match?(~r/\.tmp-[0-9]+-[0-9]+\z/, &1))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case unlink_owned(path, generation.path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp generation(%State{} = state, id) do
    case Enum.find(state.profile.generations, &(&1.generation_id == id)) do
      nil -> {:error, :generation_not_found}
      generation -> {:ok, generation}
    end
  end

  defp clear_journal(%State{} = state, opts) do
    with :ok <- sync_directory(publication_directory(state.profile.name, opts)),
         :ok <- sync_registered_roots(state, opts) do
      save(%{state | operation: nil, target: nil, previous: nil, native_before: []}, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_registered_roots(%State{} = state, opts) do
    if state.operation in ["stage", "select"] and
         Enum.any?(state.profile.generations, &(&1.generation_id == state.target)) do
      sync_directory(Path.join(config(opts).nix_state_directory, "gcroots/auto"))
    else
      :ok
    end
  end

  defp load(name, opts) do
    with {:ok, contents} <- File.read(ledger_path(name, opts)),
         {:ok, data} <- Jason.decode(contents),
         {:ok, profile} <- GardenSeedProfile.cast(data["profile"]),
         {:ok, declared} <-
           (case data["declared_retention"] do
              nil -> {:ok, nil}
              value -> SowerClient.Orchestration.ProfileRetention.cast(value)
            end),
         true <-
           profile.name == name and profile.managed == true and
             profile.profile_path == Path.join(publication_directory(name, opts), "profile") do
      {:ok,
       %State{
         profile: profile,
         operation: data["operation"],
         target: data["target"],
         previous: data["previous"],
         native_before: data["native_before"] || [],
         declared_retention: declared,
         blocked_boot_id: data["blocked_boot_id"]
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_ownership_record}
    end
  end

  defp save(%State{} = state, opts) do
    path = ledger_path(state.profile.name, opts)

    contents =
      Jason.encode!(%{
        profile: state.profile,
        operation: state.operation,
        target: state.target,
        previous: state.previous,
        native_before: state.native_before,
        declared_retention: state.declared_retention,
        blocked_boot_id: state.blocked_boot_id
      })

    with :ok <- File.write(path <> ".tmp", contents, [:sync]),
         :ok <- File.rename(path <> ".tmp", path),
         :ok <- sync_directory(ledger_directory(opts)) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp command(%State{} = state, program, args, opts) do
    with {:ok, boot_id} <- read_boot_id(opts),
         {:ok, pid, ospid} <- Rexec.run([program | args]) do
      case command_output(pid, ospid, opts, []) do
        :ok ->
          :ok

        {:error, :process_cleanup_unconfirmed} = error ->
          case save(
                 %{
                   state
                   | blocked_boot_id: boot_id,
                     profile: %{
                       state.profile
                       | last_error: "Native process cleanup is unconfirmed"
                     }
                 },
                 opts
               ) do
            {:ok, _} -> error
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_boot_id(opts) do
    path =
      Keyword.get(opts, :boot_id_file) ||
        System.get_env("VM_MANAGER_BOOT_ID_FILE") || "/proc/sys/kernel/random/boot_id"

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> {:error, :boot_identity_unavailable}
          boot_id -> {:ok, boot_id}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp command_output(pid, ospid, opts, output) do
    receive do
      {stream, ^ospid, data} when stream in [:stdout, :stderr] ->
        Keyword.get(opts, :on_output, fn _ -> :ok end).(data)
        command_output(pid, ospid, opts, [data | output])

      {:EXIT, _supervisor, :shutdown} ->
        Rexec.kill_tree(pid, :sigkill)
        command_output(pid, ospid, opts, output)

      {:cleanup_error, ^ospid, _message} ->
        command_output(pid, ospid, opts, output)

      {:DOWN, _ref, :process, ^pid, :normal} ->
        :ok

      {:DOWN, _ref, :process, ^pid, {:shutdown, {:exit_status, code}}} ->
        {:error, {:nix_failed, code, output |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:DOWN, _ref, :process, ^pid, {:shutdown, {:signal, signal}}} ->
        {:error, {:nix_signalled, signal}}

      {:DOWN, _ref, :process, ^pid, _reason} ->
        {:error, :process_cleanup_unconfirmed}
    end
  end

  defp sync_directory(directory) do
    case System.find_executable("sower") do
      nil ->
        {:error, :directory_sync_unavailable}

      executable ->
        case System.cmd(executable, ["internal", "sync-directory", directory],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, code} -> {:error, {:directory_sync_failed, code, output}}
        end
    end
  end

  defp now(opts), do: Keyword.get(opts, :now, &DateTime.utc_now/0).()
  defp ledger_directory(opts), do: Path.join(config(opts).state_directory, "managed-profiles")
  defp ledger_path(name, opts), do: Path.join(ledger_directory(opts), name <> ".json")

  defp publication_directory(name, opts),
    do: Path.join(config(opts).managed_profiles_directory, name)

  defp config(opts), do: Keyword.get_lazy(opts, :config, &Garden.Config.get/0)
end
