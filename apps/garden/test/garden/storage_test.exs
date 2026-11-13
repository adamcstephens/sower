defmodule Garden.StorageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    original = Garden.Config.get()
    Application.put_env(:garden, :config, %{original | state_directory: tmp_dir})
    on_exit(fn -> Application.put_env(:garden, :config, original) end)
    %{storage_file: Path.join(tmp_dir, "storage.etf")}
  end

  test "fresh storage exposes an empty subscription inventory", %{storage_file: file} do
    pid = start_supervised!({Garden.Storage, name: nil})
    assert GenServer.call(pid, :read).subscriptions == []
    assert file |> File.read!() |> :erlang.binary_to_term() |> Map.fetch!(:subscriptions) == []
  end

  test "migrates and persists the legacy nil subscription inventory", %{storage_file: file} do
    legacy = %Garden.Storage{subscriptions: nil, garden_sid: "existing"}
    File.write!(file, :erlang.term_to_binary(legacy))
    pid = start_supervised!({Garden.Storage, name: nil})

    assert GenServer.call(pid, :read).subscriptions == []
    assert GenServer.call(pid, :read).garden_sid == "existing"
    assert file |> File.read!() |> :erlang.binary_to_term() |> Map.fetch!(:subscriptions) == []
  end

  test "stale subscription snapshots cannot resurrect an uninstalled SID or erase its replacement",
       %{storage_file: file} do
    old =
      SowerClient.Orchestration.Subscription.cast!(%{
        name: "application",
        sid: "old-subscription",
        seed_name: "application",
        seed_type: "package",
        origin: "operator"
      })

    replacement = %{old | sid: "replacement-subscription"}
    File.write!(file, :erlang.term_to_binary(%Garden.Storage{subscriptions: [old]}))
    pid = start_supervised!({Garden.Storage, name: nil})

    assert [] = GenServer.call(pid, {:remove_subscription, old.name, old.sid})
    assert :ok = GenServer.call(pid, {:put, :subscriptions, [replacement]})
    assert :ok = GenServer.call(pid, {:put, :subscriptions, [old]})
    assert GenServer.call(pid, :read).subscriptions == [replacement]

    stop_supervised!(Garden.Storage)
    pid = start_supervised!({Garden.Storage, name: nil})
    assert :ok = GenServer.call(pid, {:put, :subscriptions, [old]})
    assert GenServer.call(pid, :read).subscriptions == [replacement]
    assert GenServer.call(pid, :read).removed_subscription_sids == [old.sid]
  end

  test "explicit uninstall removes only its captured name and SID", %{storage_file: file} do
    removed =
      SowerClient.Orchestration.Subscription.cast!(%{
        name: "application",
        sid: "old-subscription",
        seed_name: "application",
        seed_type: "package"
      })

    replacement = %{removed | sid: "new-subscription"}
    other = %{removed | name: "other", sid: "other-subscription"}

    File.write!(
      file,
      :erlang.term_to_binary(%Garden.Storage{subscriptions: [replacement, other]})
    )

    pid = start_supervised!({Garden.Storage, name: nil})

    assert [^replacement, ^other] =
             GenServer.call(pid, {:remove_subscription, removed.name, removed.sid})

    assert [^other] =
             GenServer.call(pid, {:remove_subscription, replacement.name, replacement.sid})

    stop_supervised!(Garden.Storage)
    pid = start_supervised!({Garden.Storage, name: nil})
    assert GenServer.call(pid, :read).subscriptions == [other]
  end

  for {label, bytes} <- [{"empty", <<>>}, {"truncated", <<131, 116, 0, 0, 0, 1>>}] do
    test "recovers #{label} storage and persists subsequent changes across restart", %{
      storage_file: file
    } do
      File.write!(file, unquote(bytes))

      logs =
        capture_log(fn ->
          pid = start_supervised!({Garden.Storage, name: nil})
          assert GenServer.call(pid, :read) == %Garden.Storage{}
          assert file |> File.read!() |> :erlang.binary_to_term() == %Garden.Storage{}
          assert :ok = GenServer.call(pid, {:put, :garden_sid, "recovered-garden"})
          stop_supervised!(Garden.Storage)

          pid = start_supervised!({Garden.Storage, name: nil})
          assert GenServer.call(pid, :read).garden_sid == "recovered-garden"
        end)

      assert logs =~ "warning"
      assert logs =~ file
    end
  end

  test "preserves credentials while migrating older storage", %{storage_file: file} do
    stored = %Garden.Storage{garden_sid: "existing-garden", oauth_credentials: %{token: "secret"}}
    old = Map.delete(stored, :credentials_rejected_at)
    File.write!(file, :erlang.term_to_binary(old))

    pid = start_supervised!({Garden.Storage, name: nil})
    assert GenServer.call(pid, :read) == stored
    assert file |> File.read!() |> :erlang.binary_to_term() == stored
  end

  test "does not recover filesystem read errors", %{storage_file: file} do
    File.mkdir!(file)
    assert {:error, _reason} = start_supervised({Garden.Storage, name: nil})
    assert File.dir?(file)
  end
end
