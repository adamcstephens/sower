defmodule Garden.VM.ProtocolTest do
  use ExUnit.Case, async: true

  test "rejects oversized frames from their header without waiting for a payload" do
    assert {:error, {:frame_too_large, 65_537}} =
             Garden.VM.Protocol.decode_frame(<<2, 65_537::unsigned-big-32>>)
  end

  test "waits for a fragmented binary payload and consumes only one complete frame" do
    payload = <<0, 255, 10, 254>>
    following = metadata(%{"type" => "exited", "version" => 1, "code" => 23, "signal" => nil})
    assert :more = Garden.VM.Protocol.decode_frame(<<2, 4::unsigned-big-32, 0, 255>>)

    assert {:ok, {:stdout, ^payload}, ^following} =
             Garden.VM.Protocol.decode_frame(frame(2, payload) <> following)

    assert {:ok, {:exited, 23, nil}, <<>>} =
             Garden.VM.Protocol.decode_frame(following)
  end

  test "preserves signal termination separately from command exit status" do
    assert {:ok, {:exited, nil, 9}, <<>>} =
             Garden.VM.Protocol.decode_frame(
               metadata(%{"type" => "exited", "version" => 1, "code" => nil, "signal" => 9})
             )
  end

  test "rejects an unknown frame kind" do
    assert {:error, {:unknown_frame_kind, 4}} =
             Garden.VM.Protocol.decode_frame(<<4, 0::unsigned-big-32>>)
  end

  test "rejects malformed metadata JSON" do
    assert {:error, :invalid_metadata_json} =
             Garden.VM.Protocol.decode_frame(frame(1, "{"))
  end

  test "rejects unsupported guest event versions" do
    assert {:error, {:unsupported_event_version, 2}} =
             Garden.VM.Protocol.decode_frame(metadata(%{"type" => "ready", "version" => 2}))
  end

  test "rejects terminal events that ambiguously contain both exit code and signal" do
    assert {:error, :invalid_exit_status} =
             Garden.VM.Protocol.decode_frame(
               metadata(%{"type" => "exited", "version" => 1, "code" => 1, "signal" => 9})
             )
  end

  test "rejects terminal events without an exit code or signal" do
    assert {:error, :invalid_exit_status} =
             Garden.VM.Protocol.decode_frame(
               metadata(%{"type" => "exited", "version" => 1, "code" => nil, "signal" => nil})
             )
  end

  test "rejects a guest error event without a string message" do
    assert {:error, :invalid_error_event} =
             Garden.VM.Protocol.decode_frame(
               metadata(%{"type" => "error", "version" => 1, "message" => 42})
             )
  end

  test "rejects unknown guest metadata events" do
    assert {:error, {:unknown_event_type, "execute"}} =
             Garden.VM.Protocol.decode_frame(metadata(%{"type" => "execute", "version" => 1}))
  end

  defp metadata(event), do: frame(1, Jason.encode!(event))

  defp frame(kind, payload), do: <<kind, byte_size(payload)::unsigned-big-32, payload::binary>>
end
