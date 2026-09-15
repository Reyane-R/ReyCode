defmodule ReyCode.Orchestration.ChallengeTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Challenge,
    Invocation,
    Message,
    Projection,
    Session,
    StrategicReview,
    ToolRun,
    Turn
  }

  setup do
    session = %Session{id: "s", workspace: "/workspace", message_order: ["answer"]}

    message = %Message{
      id: "answer",
      session_id: "s",
      turn_id: "t",
      invocation_id: "i",
      role: :assistant,
      body: "The fix works."
    }

    run = %ToolRun{
      id: "run",
      tool_call_id: "call",
      tool: "bash",
      workspace: "/workspace",
      status: :completed,
      arguments: %{"command" => "mix test"},
      result: %{"output" => "1 test passed", "truncated" => false}
    }

    invocation = %Invocation{
      id: "i",
      turn_id: "t",
      session_id: "s",
      message_id: "answer",
      tool_run_order: ["run"],
      tool_runs: %{"run" => run}
    }

    turn = %Turn{
      id: "t",
      session_id: "s",
      status: :terminal,
      outcome: :completed,
      user_message_id: "input",
      invocation_order: ["other1", "other2", "i"]
    }

    projection = %Projection{
      sequence: 42,
      sessions: %{"s" => session},
      messages: %{"answer" => message, "input" => %Message{id: "input", body: "Fix it"}},
      turns: %{"t" => turn},
      invocations: %{"i" => invocation}
    }

    %{projection: projection, session: session}
  end

  test "selected answer is retained even beyond the ordinary first-two-invocations window",
       context do
    assert {:ok, packet} =
             Challenge.capture(
               context.projection,
               context.session,
               [],
               selection("answer", "answer")
             )

    assert [%{"outputs" => [%{"message_id" => "answer", "invocation_id" => "i"}]}] = packet.turns
    assert packet.projection_sequence == 42
    assert hd(packet.turns)["invocations_omitted"]
    assert {:ok, source} = Challenge.source(packet, "T1.I1.R1")
    assert source["tool_run_id"] == "run"
    assert source["output"]["text"] == "1 test passed"
    assert source["artifact"]["availability"] == "unknown"
    assert {:error, :evidence_not_in_packet} = Challenge.source(packet, "invented")
    assert StrategicReview.from_map(StrategicReview.to_wire(packet)) == packet
  end

  test "foreign, stale, unfinished and non-answer targets cannot queue a challenge", context do
    assert {:error, :invalid_challenge_target} =
             Challenge.capture(
               context.projection,
               context.session,
               [],
               selection("answer", "missing")
             )

    for changes <- [%{session_id: "foreign"}, %{role: :user}, %{invocation_id: "other1"}] do
      original = context.projection
      projection = update_in(original.messages["answer"], &Map.merge(&1, changes))

      assert {:error, :invalid_challenge_target} =
               Challenge.capture(projection, context.session, [], selection("answer", "answer"))
    end

    original = context.projection
    projection = update_in(original.turns["t"], &%{&1 | status: :running})

    assert {:error, :invalid_challenge_target} =
             Challenge.capture(projection, context.session, [], selection("answer", "answer"))
  end

  test "decision capture isolates its workspace and records invalidation and missing evidence",
       context do
    memory = %{
      id: "m",
      project: "/workspace",
      kind: "decision",
      key: "choice",
      value: "An unverified rationale",
      active: false,
      created_at: "now"
    }

    assert {:ok, packet} =
             Challenge.capture(
               context.projection,
               context.session,
               [memory],
               selection("decision", "m")
             )

    assert packet.turns == []
    assert {:ok, %{"memory_id" => "m", "active" => false}} = Challenge.source(packet, "M1")
    assert packet.focus =~ "free-text evidence is a claim"

    assert {:error, :challenge_evidence_unavailable} =
             Challenge.capture(
               context.projection,
               context.session,
               [%{memory | project: "/elsewhere"}],
               selection("decision", "m")
             )
  end

  test "follow-up experiments require validated citations", context do
    {:ok, packet} =
      Challenge.capture(context.projection, context.session, [], selection("answer", "answer"))

    finding = %{
      observation: "Test passed",
      hypothesis: "The bug may be fixed",
      alternative: "Keep the simpler implementation",
      tradeoffs: "Less code",
      experiment: "Run the original reproduction",
      uncertainty: "One test is limited",
      recurring: false,
      citations: ["T1.I1.R1"]
    }

    report = fn finding ->
      Jason.encode!(%{
        summary: "Limited evidence",
        limitations: "Captured preview only",
        findings: [finding]
      })
    end

    assert {:ok, ["Run the original reproduction"]} =
             Challenge.experiments(packet, report.(finding))

    assert {:error, :invalid_strategic_output} =
             Challenge.experiments(packet, report.(%{finding | citations: ["invented"]}))
  end

  defp selection(kind, id), do: %{"kind" => kind, "id" => id, "question" => "support"}
end
