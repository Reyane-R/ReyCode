defmodule ReyCode.OneShotTest do
  use ExUnit.Case, async: false

  alias ReyCode.CLI.Run
  alias ReyCode.OneShot
  alias ReyCode.Orchestration.{Engine, Validation}

  test "parses option, positional, and piped prompts through one contract" do
    assert {:ok, %{prompt: "from option"}} = Run.parse(["-p", "from option"])
    assert {:ok, %{prompt: "from positional words"}} = Run.parse(["from", "positional", "words"])

    assert {:ok, %{prompt: "from pipe"}} =
             Run.parse([], stdin_reader: fn -> {:ok, "from pipe\n"} end)

    assert {:error, message} = Run.parse(["-p", "one", "two"])
    assert message =~ "choose either -p or positional"
  end

  test "rejects oversized piped input before orchestration" do
    oversized = String.duplicate("x", Validation.message_max_bytes() + 1)

    assert {:error, message} = Run.parse([], stdin_reader: fn -> {:ok, oversized} end)
    assert message =~ "exceeds"
  end

  test "renders orchestration startup errors without raising" do
    assert {:error, %{outcome: :failed, error: "invalid_timeout"}} =
             OneShot.run(%{
               prompt: "Do not start",
               workspace: File.cwd!(),
               timeout_ms: 0
             })
  end

  test "runs one durable Primary Assistant turn and returns its response" do
    assert {:ok, report} =
             OneShot.run(%{
               prompt: "Return a concise one-shot response",
               workspace: File.cwd!(),
               timeout_ms: 5_000
             })

    assert report.outcome == :completed
    assert report.session_id
    assert report.turn_id
    assert is_binary(report.response)
    assert report.response != ""

    snapshot = Engine.snapshot()
    assert snapshot.turns[report.turn_id].status == :terminal
  end

  test "renders machine-readable output" do
    assert {:ok, encoded} =
             Run.execute(
               ["-p", "Return JSON-compatible output", "--json", "--timeout-ms", "5000"],
               engine: Engine
             )

    assert {:ok, decoded} = Jason.decode(encoded)
    assert decoded["outcome"] == "completed"
    assert is_binary(decoded["response"])
  end
end
