defmodule VMManager.ProtocolTest do
  use ExUnit.Case, async: true

  test "rejects oversized frames from their header without waiting for a payload" do
    assert {:error, {:frame_too_large, 65_537}} =
             VMManager.Protocol.decode_frame(<<2, 65_537::unsigned-big-32>>)
  end

  test "waits for a fragmented binary payload and consumes only one complete frame" do
    payload = <<0, 255, 10, 254>>
    following = metadata(%{"type" => "exited", "version" => 1, "code" => 23, "signal" => nil})
    assert :more = VMManager.Protocol.decode_frame(<<2, 4::unsigned-big-32, 0, 255>>)

    assert {:ok, {:stdout, ^payload}, ^following} =
             VMManager.Protocol.decode_frame(frame(2, payload) <> following)

    assert {:ok, {:exited, 23, nil}, <<>>} =
             VMManager.Protocol.decode_frame(following)
  end

  test "preserves signal termination separately from command exit status" do
    assert {:ok, {:exited, nil, 9}, <<>>} =
             VMManager.Protocol.decode_frame(
               metadata(%{"type" => "exited", "version" => 1, "code" => nil, "signal" => 9})
             )
  end

  test "rejects an unknown frame kind" do
    assert {:error, {:unknown_frame_kind, 4}} =
             VMManager.Protocol.decode_frame(<<4, 0::unsigned-big-32>>)
  end

  test "rejects malformed metadata JSON" do
    assert {:error, :invalid_metadata_json} =
             VMManager.Protocol.decode_frame(frame(1, "{"))
  end

  test "rejects unsupported guest event versions" do
    assert {:error, {:unsupported_event_version, 3}} =
             VMManager.Protocol.decode_frame(metadata(%{"type" => "ready", "version" => 3}))
  end

  test "rejects terminal events that ambiguously contain both exit code and signal" do
    assert {:error, :invalid_exit_status} =
             VMManager.Protocol.decode_frame(
               metadata(%{"type" => "exited", "version" => 1, "code" => 1, "signal" => 9})
             )
  end

  test "rejects terminal events without an exit code or signal" do
    assert {:error, :invalid_exit_status} =
             VMManager.Protocol.decode_frame(
               metadata(%{"type" => "exited", "version" => 1, "code" => nil, "signal" => nil})
             )
  end

  test "rejects a guest error event without a string message" do
    assert {:error, :invalid_error_event} =
             VMManager.Protocol.decode_frame(
               metadata(%{"type" => "error", "version" => 1, "message" => 42})
             )
  end

  test "rejects unknown guest metadata events" do
    assert {:error, {:unknown_event_type, "execute"}} =
             VMManager.Protocol.decode_frame(metadata(%{"type" => "execute", "version" => 1}))
  end

  test "encodes argv environment and JSON stdin without shell interpolation" do
    command = %VMManager.Command{
      path: "/bin/example",
      args: ["one two", "$(false)", ""],
      env: %{"VALUE" => "a=b\nc"},
      stdin: %{"binary" => [0, 255], "nested" => %{"ok" => true}}
    }

    assert {:ok, <<1, size::unsigned-big-32, payload::binary>>} =
             VMManager.Protocol.execute(command, 2)

    assert byte_size(payload) == size

    assert %{"path" => "/bin/example", "args" => args, "env" => env, "stdin" => stdin} =
             Jason.decode!(payload)

    assert args == command.args
    assert env == command.env
    assert stdin == command.stdin
  end

  defp metadata(event), do: frame(1, Jason.encode!(event))

  defp frame(kind, payload), do: <<kind, byte_size(payload)::unsigned-big-32, payload::binary>>
end
