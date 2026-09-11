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
