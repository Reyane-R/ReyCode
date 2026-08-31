defmodule ReyCode.Orchestration.PeerMessageTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.PeerMessage

  @fields %{
    id: "peer-1",
    sender_invocation_id: "inv-1",
    sender_name: "Scout",
    target_invocation_id: "inv-2",
    body: "found the failing test",
    created_sequence: 42
  }

  test "from_map returns typed messages unchanged" do
    message = struct!(PeerMessage, @fields)

    assert PeerMessage.from_map(message) == message
  end

  test "from_map builds the typed record from a decoded map and drops unknown keys" do
    decoded = Map.merge(@fields, %{extra: "ignored"})

    assert PeerMessage.from_map(decoded) == struct!(PeerMessage, @fields)
  end
end
