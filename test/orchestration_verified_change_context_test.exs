defmodule ReyCode.Orchestration.VerifiedChangeContextTest do
  use ExUnit.Case, async: true

  alias ReyCode.{Event, EventStore, RuntimeConfig}

  alias ReyCode.Orchestration.{
    Author,
    ContextCompaction,
    Engine,
    Invocation,
    InvocationRequest,
    Message,
    Projection,
    Projector,
    Session,
    Turn,
    VerifiedChange,
    VerifiedChangeContext
  }

  alias ReyCode.ProjectInstructions.Capture

  test "complete goal and ordered commands survive compacted snapshots on every round and repair" do
    record = record()
    contract = VerifiedChangeContext.prompt(record)

    session = %Session{
      id: "session",
      verified_change: record,
      message_order: ["goal", "recent"]
    }

    projection = %Projection{
      sequence: 4,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{
        "goal" => message("goal", contract, 2),
        "recent" => message("recent", String.duplicate("recent work ", 1_000), 3)
      },
      turns: %{
        "turn" => %Turn{id: "turn", mode: :direct, context_through_sequence: 4}
      }
    }

    assert {:compact, {:context_compacted, data, metadata}} =
             ContextCompaction.entry(session, projection, 100)

    projection = Projector.apply(Event.new(5, :context_compacted, data, metadata), projection)
    compacted = projection.sessions[session.id]
    refute compacted.context_summary =~ record.prompt
    refute compacted.context_summary =~ hd(record.commands)

    for phase <- ~w(implementing repairing),
        rounds <- [[], [%{index: 0, text: "Continue editing", tool_calls: [], usage: nil}]],
        instructions <- [
          nil,
          %Capture{content: "", digest: "empty", sources: []},
          %Capture{content: "Frozen project rules", digest: "rules", sources: []}
        ] do
      current = %{record | phase: phase, repair_count: if(phase == "repairing", do: 1, else: 0)}
      snapshot = put_in(projection.sessions[session.id], %{compacted | verified_change: current})

      invocation = %Invocation{
        id: "invocation",
        session_id: session.id,
        turn_id: "turn",
        system_prompt: "Participant instructions",
        project_instructions: instructions,
        rounds: rounds,
        attempt: 2
      }

      request = InvocationRequest.build(invocation, snapshot, policy())
      assert request.system_prompt =~ "Participant instructions"
      assert request.system_prompt =~ VerifiedChangeContext.prompt(current)
      assert request.round_index == length(rounds)
      refute Enum.any?(request.messages, &String.contains?(&1.content, record.prompt))

      if instructions && instructions.content != "" do
        assert request.system_prompt =~ instructions.content
      end
    end
  end

  test "contract keeps exact goal, commands, limits and indexed bounded evidence" do
    record = record()

    report = %{
      "command" => hd(record.commands),
      "exit_code" => 1,
      "output" => String.duplicate("output ", 100),
      "error" => String.duplicate("error ", 100),
      "snapshot_hash" => "snapshot"
    }

    prompt = VerifiedChangeContext.prompt(%{record | baseline: [report], checks: [report]})
    [_instructions, json] = String.split(prompt, "\n", parts: 2)
    decoded = Jason.decode!(json)
    assert decoded["prompt"] == record.prompt
    assert decoded["commands"] == record.commands
    assert decoded["phase"] == record.phase
    assert decoded["max_repair_count"] == record.max_repair_count
    assert decoded["timeout_ms"] == record.timeout_ms
    assert decoded["check_timeout_ms"] == record.check_timeout_ms

    for field <- ~w(baseline checks) do
      [preview] = decoded[field]
      assert preview["command_index"] == 1
      refute Map.has_key?(preview, "command")
      assert preview["snapshot_hash"] == "snapshot"
      assert preview["exit_code"] == 1
      assert byte_size(preview["output"]) <= 256
      assert byte_size(preview["error"]) <= 256
      assert preview["output_is_preview"]
      assert preview["error_is_preview"]
    end
  end

  test "contract admission uses encoded bytes and accepts the exact estimated boundary" do
    record = %{record() | prompt: String.duplicate("\"\\\n", 10_000)}
    [_instructions, json] = String.split(VerifiedChangeContext.prompt(record), "\n", parts: 2)
    assert Jason.decode!(json)["prompt"] == record.prompt
    minimum_tokens = div(byte_size(VerifiedChangeContext.prompt(record)) + 3, 4)
    assert :ok = VerifiedChangeContext.admit(nil, 1)
    assert :ok = VerifiedChangeContext.admit(record, minimum_tokens)
    assert {:error, error} = VerifiedChangeContext.admit(record, minimum_tokens - 1)
    assert error =~ "increase context_budget_tokens to at least #{minimum_tokens}"
    assert error =~ "not truncated"
  end

  test "complete evidence is not marked as a preview and absent errors stay absent" do
    report = %{
      "command" => "mix test",
      "exit_code" => 0,
      "output" => String.duplicate("x", 256),
      "error" => nil,
      "snapshot_hash" => "snapshot"
    }

    prompt = VerifiedChangeContext.prompt(%{record() | baseline: [report]})
    [_instructions, json] = String.split(prompt, "\n", parts: 2)
    [evidence] = Jason.decode!(json)["baseline"]
    assert evidence["output"] == report["output"]
    assert evidence["error"] == nil
    refute evidence["output_is_preview"]
    refute evidence["error_is_preview"]
  end

  @tag :tmp_dir
  test "Engine rejects oversized frozen contract before append, compaction or model work",
       %{tmp_dir: dir} do
    config = RuntimeConfig.fresh(context_budget_tokens: 1, provider_discovery: false)
    registry = __MODULE__.Events
    start_supervised!({Registry, keys: :duplicate, name: registry})
    store = start_supervised!({EventStore, name: nil, path: Path.join(dir, "context.sqlite3")})

    engine =
      start_supervised!(
        {Engine, name: nil, event_store: store, event_registry: registry, config: config}
      )

    session_id = hd(Engine.snapshot(engine).session_order)

    assert :ok =
             Engine.record_verified_change(session_id, VerifiedChange.to_wire(record()), engine)

    before = Engine.snapshot(engine)
    assert {:error, error} = Engine.post_message(session_id, "Implement", :direct, engine)
    assert error =~ "Verified-change contract requires"
    assert error =~ "context_budget_tokens permits 4 bytes"
    assert error =~ "increase context_budget_tokens"
    assert Engine.snapshot(engine) == before
    assert before.invocations == %{}
    assert Projector.replay(EventStore.load(store)) == before
  end

  defp record do
    {:ok, record} =
      VerifiedChange.from_wire(%{
        "id" => "change",
        "phase" => "preparing",
        "source_workspace" => "/source",
        "workspace" => "/candidate",
        "base_commit" => "base",
        "prompt" => "Preserve the exact frozen goal, including its final requirement.",
        "commands" => ["mix test --only contract", "mix compile --warnings-as-errors"],
        "max_repair_count" => 2,
        "repair_count" => 0,
        "timeout_ms" => 60_000,
        "check_timeout_ms" => 10_000
      })

    record
  end

  defp message(id, body, sequence) do
    %Message{
      id: id,
      session_id: "session",
      author: Author.user("You"),
      role: :user,
      status: :completed,
      body: body,
      created_sequence: sequence
    }
  end

  defp policy, do: %{agent_delay_ms: 0, simulator_opts: []}
end
