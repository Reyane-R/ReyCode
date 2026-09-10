defmodule ReyCode.Orchestration.StrategicReviewTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Invocation,
    Message,
    Projection,
    Session,
    StrategicReview,
    ToolRun,
    Turn
  }

  test "workspace-wide selection includes every outcome, ignores fork references and review Turns" do
    {projection, session} = history(5)
    other = %Session{id: "other", workspace: "/other"}
    fork = %Session{id: "fork", workspace: session.workspace, message_order: ["message-1"]}
    review = %{projection.turns["turn-1"] | id: "review", strategy_review: %{}}
    foreign = %{projection.turns["turn-1"] | id: "foreign", session_id: other.id}
    running = %{projection.turns["turn-1"] | id: "running", status: :running}

    projection = %{
      projection
      | sessions: Map.merge(projection.sessions, %{other.id => other, fork.id => fork}),
        turns:
          Map.merge(projection.turns, %{
            "review" => review,
            "foreign" => foreign,
            "running" => running
          })
    }

    assert {:ok, packet} = StrategicReview.capture(projection, session, [], nil)
    assert length(packet.turns) == 5

    assert Enum.sort(Enum.map(packet.turns, & &1["outcome"])) ==
             ~w(cancelled completed failed partial reworked)

    assert packet.coverage["scanned_turn_count"] == 8
    assert packet.coverage["eligible_turn_count"] == 5
    assert packet.coverage["limitations"] =~ "Fork transcript references"
    assert packet.focus == ""
  end

  test "newest bounded selection and memory snapshot are deterministic and round-trip" do
    {projection, session} = history(12)
    memories = Enum.map(1..25, &memory/1)
    assert {:ok, packet} = StrategicReview.capture(projection, session, memories, "Direction")

    assert {:ok, ^packet} =
             StrategicReview.capture(projection, session, Enum.reverse(memories), "Direction")

    assert length(packet.turns) == 8
    assert hd(packet.turns)["turn_id"] == "turn-12"
    assert length(packet.memory) == 20
    assert Enum.any?(packet.memory, &(not &1["active"]))
    assert packet.coverage["omitted_turn_count"] == 4
    assert packet.coverage["omitted_memory_count"] == 5
    assert packet.coverage["limitations"] =~ "not atomic with projection_sequence"
    assert StrategicReview.from_map(packet) == packet
    assert StrategicReview.from_map(Map.from_struct(packet)) == packet

    assert packet
           |> StrategicReview.to_wire()
           |> Jason.encode!()
           |> Jason.decode!()
           |> StrategicReview.from_map() == packet

    assert StrategicReview.prompt(packet) =~ Jason.encode!(StrategicReview.to_wire(packet))
  end

  test "clips UTF-8 explicitly without reading artifacts or long Invocation lists" do
    {projection, session} = history(1)
    text = String.duplicate("\u20ac", 1000)
    message = %{projection.messages["message-1"] | body: text}
    invocation = %Invocation{id: "invocation", message_id: message.id}
    turn = %{projection.turns["turn-1"] | invocation_order: List.duplicate(invocation.id, 1000)}

    projection = %{
      projection
      | messages: %{message.id => message},
        turns: %{turn.id => turn},
        invocations: %{invocation.id => invocation}
    }

    assert {:ok, packet} =
             StrategicReview.capture(projection, session, [%{memory(1) | value: text}], "")

    source = hd(packet.turns)
    assert source["input"]["clipped"]
    assert String.valid?(source["input"]["text"])
    assert byte_size(source["input"]["text"]) == 1023
    assert byte_size(hd(packet.memory)["value"]["text"]) == 1023
    assert length(source["outputs"]) == 2
    assert source["invocations_omitted"]
    assert hd(packet.memory)["value"]["clipped"]
    assert byte_size(Jason.encode!(StrategicReview.to_wire(packet))) <= 65_536
  end

  test "selection limits and invalid focus fail explicitly" do
    {projection, session} = history(1)

    assert {:error, :strategy_review_selection_limit} =
             StrategicReview.capture(projection, session, Enum.map(1..101, &memory/1), "")

    turns = Map.new(1..10_001, &{&1, hd(Map.values(projection.turns))})

    assert {:error, :strategy_review_selection_limit} =
             StrategicReview.capture(%{projection | turns: turns}, session, [], "")

    for focus <- [42, <<255>>, String.duplicate("x", 4097)] do
      assert {:error, :invalid_strategy_review_focus} =
               StrategicReview.capture(projection, session, [], focus)
    end
  end

  test "verified reports are excluded without excluding implementation or repair" do
    {projection, session} = history(3)

    record = %ReyCode.Orchestration.VerifiedChange{
      analysis: %{"turn_id" => "turn-1"},
      metadata: nil
    }

    session = %{session | verified_change: record}
    projection = %{projection | sessions: Map.put(projection.sessions, session.id, session)}
    assert {:ok, packet} = StrategicReview.capture(projection, session, [], "")
    assert Enum.map(packet.turns, & &1["turn_id"]) == ["turn-3", "turn-2"]
  end

  test "JSON escaping cannot exceed the encoded packet budget" do
    {projection, session} = history(8)
    text = String.duplicate(<<0>>, 2000)
    messages = Map.new(projection.messages, fn {id, message} -> {id, %{message | body: text}} end)
    memories = Enum.map(1..20, &%{memory(&1) | key: text, value: text})

    assert {:ok, packet} =
             StrategicReview.capture(%{projection | messages: messages}, session, memories, "")

    assert length(packet.turns) == 8
    assert length(packet.memory) == 20
    assert byte_size(Jason.encode!(StrategicReview.to_wire(packet))) <= 65_536
    assert hd(packet.memory)["value"]["clipped"]
  end

  test "restoration rejects malformed nested data and inconsistent coverage" do
    {projection, session} = history(2)
    {:ok, packet} = StrategicReview.capture(projection, session, [memory(1)], "")
    wire = StrategicReview.to_wire(packet)

    for malformed <- [
          nil,
          %{},
          Map.put(wire, "extra", true),
          Map.put(wire, "version", 1),
          Map.put(wire, "turns", [%{}]),
          Map.put(wire, "memory", [%{}]),
          put_in(wire, ["coverage", "omitted_turn_count"], 9),
          Map.put(wire, "focus", <<255>>),
          Map.put(wire, "turns", List.duplicate(hd(packet.turns), 2))
        ] do
      assert_raise ArgumentError, fn -> StrategicReview.from_map(malformed) end
    end
  end

  test "findings require packet-local citations and recurrence requires distinct Turns" do
    {projection, session} = history(2)
    {:ok, packet} = StrategicReview.capture(projection, session, [memory(1)], "")

    finding = finding(["T1", "T2"])

    valid = report([finding])
    assert {:ok, ^valid} = StrategicReview.validate_output(packet, valid)
    insufficient = report([])
    assert {:ok, ^insufficient} = StrategicReview.validate_output(packet, insufficient)
    single = report([%{finding | "recurring" => false, "citations" => ["M1"]}])
    assert {:ok, ^single} = StrategicReview.validate_output(packet, single)

    for invalid <- [
          "not JSON",
          "[]",
          "{}",
          <<255>>,
          String.duplicate("x", 32_769),
          report(List.duplicate(finding, 4)),
          report([%{finding | "citations" => ["T1", "M1"]}]),
          report([%{finding | "citations" => ["T1", "T1"]}]),
          report([%{finding | "citations" => ["T1", "turn-1"]}]),
          report([%{finding | "citations" => []}]),
          report([%{finding | "observation" => " "}]),
          report([Map.put(finding, "extra", true)])
        ] do
      assert {:error, :invalid_strategic_output} =
               StrategicReview.validate_output(packet, invalid)
    end
  end

  test "retains terminal tool evidence, execution Workspace and artifact metadata without fetching" do
    {projection, session} = tool_history(1)
    assert {:ok, packet} = StrategicReview.capture(projection, session, [], "")
    turn = hd(packet.turns)
    invocation = hd(turn["outputs"])
    tool = hd(invocation["tools"])

    assert turn["input_message_id"] == "message-1"
    assert invocation["invocation_id"] == "invocation-1-1"
    assert invocation["message_id"] == "report-1-1"
    assert invocation["report"]["text"] == "Implementation report"
    refute invocation["report"]["missing"]
    assert tool["source_id"] == "T1.I1.R1"
    assert tool["tool_run_id"] == "run-1-1-1"
    assert tool["tool_call_id"] == "call-1-1-1"
    assert tool["invocation_id"] == invocation["invocation_id"]
    assert tool["message_id"] == invocation["message_id"]
    assert tool["workspace"] == "/isolated/candidate"
    assert packet.workspace == "/workspace"
    assert tool["status"] == "completed"
    assert tool["arguments"]["format"] == "json_preview"
    assert Jason.decode!(tool["arguments"]["text"]) == %{"command" => "mix test"}
    assert tool["output"]["text"] == "A retained output preview"
    assert tool["error"]["missing"]
    assert tool["output_truncated"]

    assert tool["artifact"] == %{
             "id" => "not-present-on-disk",
             "bytes" => 100_000,
             "complete" => false,
             "contents_read" => false,
             "availability" => "unknown"
           }

    failed = List.last(invocation["tools"])
    assert failed["status"] == "failed"
    assert failed["output"]["missing"]
    assert Jason.decode!(failed["error"]["text"]) == %{"error" => "check failed"}
    assert failed["artifact"]["id"] == nil
    assert failed["output_truncated"] == nil
    assert StrategicReview.from_map(StrategicReview.to_wire(packet)) == packet
  end

  test "tool selection is bounded and distinguishes missing references from nonterminal work" do
    {projection, session} = tool_history(1)
    invocation = projection.invocations["invocation-1-1"]
    ready = %{invocation.tool_runs["run-1-1-1"] | id: "ready", status: :ready}
    interrupted = %{ready | id: "interrupted", status: :interrupted}
    denied = %{ready | id: "denied", status: :denied}

    tool_runs =
      Map.merge(invocation.tool_runs, %{
        ready.id => ready,
        interrupted.id => interrupted,
        denied.id => denied
      })

    order =
      ["missing", "ready", "interrupted", "denied", "run-1-1-1"] ++
        List.duplicate("missing", 1000)

    invocation = %{invocation | tool_run_order: order, tool_runs: tool_runs}

    projection = %{
      projection
      | invocations: Map.put(projection.invocations, invocation.id, invocation)
    }

    assert {:ok, packet} = StrategicReview.capture(projection, session, [], "")
    source = hd(hd(packet.turns)["outputs"])
    assert Enum.map(source["tools"], & &1["status"]) == ["interrupted", "denied"]
    assert source["scanned_tool_run_count"] == 32
    assert source["eligible_tool_run_count"] == 3
    assert source["missing_tool_run_count"] == 28
    assert source["omitted_tool_run_count"] == 1
    assert source["tool_scan_limited"]
  end

  test "missing invocation and message records are explicit, unlike present empty responses" do
    {projection, session} = history(1)
    invocation = %Invocation{id: "known", message_id: "missing-message"}
    turn = %{projection.turns["turn-1"] | invocation_order: ["missing-invocation", "known"]}

    projection = %{
      projection
      | turns: %{turn.id => turn},
        messages: %{},
        invocations: %{invocation.id => invocation}
    }

    assert {:ok, packet} = StrategicReview.capture(projection, session, [], "")
    turn = hd(packet.turns)
    assert turn["input"]["missing"]
    [missing, known] = turn["outputs"]
    assert missing["missing"] and missing["report"]["missing"]
    assert missing["message_id"] == nil
    assert missing["tools"] == []
    refute known["missing"]
    assert known["report"]["missing"]
    assert known["message_id"] == "missing-message"
    assert StrategicReview.from_map(packet) == packet
  end

  test "tool JSON previews bound nested, oversized and long values before encoding" do
    {projection, session} = tool_history(1)
    invocation = projection.invocations["invocation-1-1"]
    run = invocation.tool_runs["run-1-1-1"]

    for arguments <- [
          %{"command" => String.duplicate("\u20ac", 1000)},
          %{"config" => %{"nested" => %{"too_deep" => "secret"}}},
          %{"items" => Enum.to_list(1..1000)},
          Map.new(1..1000, &{"key-#{&1}", &1})
        ] do
      next = %{
        invocation
        | tool_runs: Map.put(invocation.tool_runs, run.id, %{run | arguments: arguments})
      }

      next = %{projection | invocations: Map.put(projection.invocations, next.id, next)}
      assert {:ok, packet} = StrategicReview.capture(next, session, [], "")
      tool = hd(hd(hd(packet.turns)["outputs"])["tools"])
      assert tool["arguments"]["clipped"]
      assert byte_size(tool["arguments"]["text"]) <= 512
      assert String.valid?(tool["arguments"]["text"])
      assert StrategicReview.from_map(packet) == packet
    end
  end

  test "full evidence packets trim previews deterministically rather than error on ordinary size" do
    {projection, session} = tool_history(8, String.duplicate("x", 3000))
    memories = Enum.map(1..20, &%{memory(&1) | value: String.duplicate("m", 3000)})
    assert {:ok, packet} = StrategicReview.capture(projection, session, memories, "")

    assert {:ok, ^packet} =
             StrategicReview.capture(projection, session, Enum.reverse(memories), "")

    assert length(packet.turns) == 8
    assert length(packet.memory) == 20
    assert packet.coverage["excerpt_limit_bytes"] in [768, 512, 256, 128]
    assert packet.coverage["budget_omitted_turn_count"] == 0
    assert packet.coverage["budget_omitted_memory_count"] == 0
    assert byte_size(Jason.encode!(StrategicReview.to_wire(packet))) <= 65_536
    assert StrategicReview.from_map(packet) == packet

    assert Enum.all?(packet.turns, fn turn ->
             length(turn["outputs"]) == 2 and
               Enum.all?(turn["outputs"], &(length(&1["tools"]) == 2))
           end)
  end

  test "metadata pressure removes oldest records with exact budget omission coverage" do
    {projection, session} = tool_history(8)

    invocations =
      Map.new(projection.invocations, fn {id, invocation} ->
        tools =
          Map.new(invocation.tool_runs, fn {id, tool} ->
            {id, %{tool | workspace: "/" <> String.duplicate("x", 4095)}}
          end)

        {id, %{invocation | tool_runs: tools}}
      end)

    assert {:ok, packet} =
             StrategicReview.capture(
               %{projection | invocations: invocations},
               session,
               Enum.map(1..20, &memory/1),
               ""
             )

    assert packet.coverage["excerpt_limit_bytes"] == 0
    assert packet.coverage["budget_omitted_turn_count"] > 0
    assert packet.coverage["budget_omitted_memory_count"] == 20
    assert packet.coverage["omitted_turn_count"] == 8 - length(packet.turns)
    assert hd(packet.turns)["turn_id"] == "turn-8"
    assert byte_size(Jason.encode!(StrategicReview.to_wire(packet))) <= 65_536
    assert StrategicReview.from_map(packet) == packet
  end

  test "nested source citations count owning Turns, not multiple tools or reports" do
    {projection, session} = tool_history(2)
    {:ok, packet} = StrategicReview.capture(projection, session, [], "")
    valid = report([finding(["T1.I1.R1", "T2.I2.R2"])])
    assert {:ok, ^valid} = StrategicReview.validate_output(packet, valid)

    for citations <- [
          ["T1", "T1.I1"],
          ["T1.I1.R1", "T1.I2.R2"],
          ["T1.I1.R1", "T3"],
          ["T1.I3"],
          ["T1.I1.R3"]
        ] do
      assert {:error, :invalid_strategic_output} =
               StrategicReview.validate_output(packet, report([finding(citations)]))
    end
  end

  test "all report fields are required, bounded and rendered as readable advisory Markdown" do
    {projection, session} = history(2)
    {:ok, packet} = StrategicReview.capture(projection, session, [], "")
    finding = finding(["T1", "T2"])

    for field <- ~w(observation hypothesis alternative tradeoffs experiment uncertainty),
        malformed <- [
          Map.delete(finding, field),
          Map.put(finding, field, " "),
          Map.put(finding, field, String.duplicate("x", 2049)),
          Map.put(finding, field, [])
        ] do
      assert {:error, :invalid_strategic_output} =
               StrategicReview.validate_output(packet, report([malformed]))
    end

    valid = report([finding])
    assert {:ok, ^valid} = StrategicReview.validate_output(packet, valid)
    rendered = StrategicReview.render_output(valid)
    assert rendered =~ "## Strategic Review"
    assert rendered =~ "**Limitations:** Only selected terminal work is visible"
    assert rendered =~ "**Observation:** Repeated scope drift"
    assert rendered =~ "**Alternative:** Implement a per-task acceptance checklist"
    assert rendered =~ "**Experiment:** Freeze one task's criteria"
    assert rendered =~ "**Uncertainty:** The selected sample is small"
    assert rendered =~ "**Citations:** `T1`, `T2`"
    assert StrategicReview.render_output(report([])) =~ "No findings supported"
    assert StrategicReview.prompt(packet) =~ "counterevidence"
    assert StrategicReview.prompt(packet) =~ "falsifiable"

    assert StrategicReview.prompt(packet) =~
             "implementation alternative satisfying the same requirement"

    assert StrategicReview.prompt(packet) =~ "competing causal explanations"
    assert_raise ArgumentError, fn -> StrategicReview.render_output("not a report") end
  end

  test "report boundaries allow three findings and escape Markdown without changing validated JSON" do
    {projection, session} = history(2)
    {:ok, packet} = StrategicReview.capture(projection, session, [], "")

    finding = %{
      finding(["T1", "T2"])
      | "observation" => "*claim* [untrusted](https://example.invalid)"
    }

    text = report(List.duplicate(finding, 3))
    assert {:ok, ^text} = StrategicReview.validate_output(packet, text)
    rendered = StrategicReview.render_output(text)
    assert rendered =~ "### Finding 3"
    assert rendered =~ "\\*claim\\* \\[untrusted\\]"

    report = Jason.decode!(report([]))

    for field <- ~w(summary limitations), invalid <- [nil, " ", String.duplicate("x", 2049)] do
      text = Jason.encode!(Map.put(report, field, invalid))
      assert {:error, :invalid_strategic_output} = StrategicReview.validate_output(packet, text)
      assert_raise ArgumentError, fn -> StrategicReview.render_output(text) end
    end

    for field <- ~w(summary limitations) do
      text = Jason.encode!(Map.put(report, field, String.duplicate("x", 2048)))
      assert {:ok, ^text} = StrategicReview.validate_output(packet, text)
      text = Jason.encode!(Map.delete(report, field))
      assert {:error, :invalid_strategic_output} = StrategicReview.validate_output(packet, text)
    end
  end

  test "structured memory retains useful JSON text and invalidation without inspecting live state" do
    {projection, session} = history(1)

    value =
      Jason.encode!(%{"rationale" => String.duplicate("r", 800), "alternatives" => ["defer"]})

    entry = %{memory(1) | value: value, active: false}
    foreign = %{memory(2) | project: "/elsewhere"}
    assert {:ok, packet} = StrategicReview.capture(projection, session, [entry, foreign], "")
    assert [source] = packet.memory
    assert source["value"]["text"] == value
    refute source["value"]["clipped"]
    refute source["active"]
    assert packet.coverage["supplied_memory_count"] == 2
    assert packet.coverage["eligible_memory_count"] == 1
  end

  test "durable validation rejects malformed tool evidence, provenance and budget declarations" do
    {projection, session} = tool_history(1)
    {:ok, packet} = StrategicReview.capture(projection, session, [], "")
    wire = StrategicReview.to_wire(packet)
    turn = hd(packet.turns)
    invocation = hd(turn["outputs"])
    tool = hd(invocation["tools"])

    for malformed <- [
          Map.put(tool, "status", "running"),
          Map.put(tool, "workspace", 42),
          Map.put(tool, "invocation_id", "foreign"),
          Map.put(tool, "message_id", "foreign"),
          Map.put(tool, "source_id", "T8.I1.R1"),
          Map.put(tool, "output", %{}),
          put_in(tool, ["artifact", "contents_read"], true),
          put_in(tool, ["arguments", "text"], String.duplicate("x", 513))
        ] do
      invocation = %{invocation | "tools" => [malformed, List.last(invocation["tools"])]}

      malformed = %{
        wire
        | "turns" => [%{turn | "outputs" => [invocation, List.last(turn["outputs"])]}]
      }

      assert_raise ArgumentError, fn -> StrategicReview.from_map(malformed) end
    end

    for malformed <- [
          put_in(wire, ["coverage", "excerpt_limit_bytes"], 0),
          put_in(wire, ["coverage", "budget_omitted_turn_count"], 1)
        ] do
      assert_raise ArgumentError, fn -> StrategicReview.from_map(malformed) end
    end
  end

  test "malformed nested IDs raise ArgumentError before interpolating child source IDs" do
    {projection, session} = tool_history(1)
    {:ok, packet} = StrategicReview.capture(projection, session, [memory(1)], "")
    wire = StrategicReview.to_wire(packet)
    turn = ["turns", Access.all()]
    invocation = turn ++ ["outputs", Access.all()]
    tool = invocation ++ ["tools", Access.all()]

    ids = [
      {[], ~w(session_id)},
      {turn, ~w(source_id turn_id session_id input_message_id)},
      {invocation, ~w(source_id invocation_id message_id)},
      {tool, ~w(source_id invocation_id message_id tool_run_id tool_call_id)},
      {tool ++ ["artifact"], ~w(id)},
      {["memory", Access.all()], ~w(source_id memory_id)}
    ]

    for {path, fields} <- ids,
        field <- fields,
        value <- [
          %{},
          %{"nested" => "id"},
          [],
          ["id"],
          {:id, 1},
          self(),
          :id,
          false,
          42,
          1.5,
          "",
          " ",
          <<255>>,
          String.duplicate("x", 257)
        ] do
      malformed = put_in(wire, path ++ [field], value)
      assert_invalid_packet(packet, malformed)
    end

    for path <- [turn, invocation, tool, ["memory", Access.all()]] do
      assert_invalid_packet(packet, put_in(wire, path ++ ["source_id"], nil))
      assert_invalid_packet(packet, update_in(wire, path, &Map.delete(&1, "source_id")))
    end
  end

  test "malformed nested shapes and improper lists fail through the durable ArgumentError contract" do
    {projection, session} = tool_history(1)
    {:ok, packet} = StrategicReview.capture(projection, session, [memory(1)], "")
    wire = StrategicReview.to_wire(packet)
    turn = ["turns", Access.all()]
    invocation = turn ++ ["outputs", Access.all()]
    tool = invocation ++ ["tools", Access.all()]
    memory = ["memory", Access.all()]

    records = [
      [],
      ["coverage"],
      turn,
      turn ++ ["input"],
      invocation,
      invocation ++ ["report"],
      tool,
      tool ++ ["arguments"],
      tool ++ ["output"],
      tool ++ ["error"],
      tool ++ ["artifact"],
      memory,
      memory ++ ["key"],
      memory ++ ["value"]
    ]

    for path <- records,
        value <- [
          nil,
          %{},
          %{__struct__: StrategicReview},
          [],
          ["record"],
          {:record, 1},
          self(),
          42,
          "record"
        ] do
      malformed = if path == [], do: value, else: put_in(wire, path, value)
      assert_invalid_packet(packet, malformed)
    end

    for path <- [["turns"], ["memory"], turn ++ ["outputs"], invocation ++ ["tools"]],
        value <- [nil, %{}, "list", 42, [nil], [nil | :improper], List.duplicate(%{}, 40)] do
      assert_invalid_packet(packet, put_in(wire, path, value))
    end
  end

  defp assert_invalid_packet(packet, malformed) do
    assert_raise ArgumentError, fn -> StrategicReview.from_map(malformed) end

    if is_map(malformed) do
      checkpoint =
        Map.new(Map.from_struct(packet), fn {field, _value} ->
          {field, Map.get(malformed, Atom.to_string(field))}
        end)

      assert_raise ArgumentError, fn -> StrategicReview.from_map(checkpoint) end

      assert_raise ArgumentError, fn ->
        StrategicReview.from_map(struct!(StrategicReview, checkpoint))
      end
    end
  end

  defp tool_history(count, text \\ nil) do
    {projection, session} = history(count)

    projection =
      Enum.reduce(projection.turns, projection, fn {id, turn}, projection ->
        invocations = Enum.map(1..2, &tool_invocation(turn, &1, text))

        messages =
          Map.new(
            invocations,
            &{&1.message_id, %Message{id: &1.message_id, body: text || "Implementation report"}}
          )

        %{
          projection
          | turns:
              Map.put(projection.turns, id, %{
                turn
                | invocation_order: Enum.map(invocations, & &1.id)
              }),
            invocations: Map.merge(projection.invocations, Map.new(invocations, &{&1.id, &1})),
            messages: Map.merge(projection.messages, messages)
        }
      end)

    {projection, session}
  end

  defp tool_invocation(turn, invocation_index, text) do
    suffix = "#{String.replace_prefix(turn.id, "turn-", "")}-#{invocation_index}"

    runs =
      Enum.map(1..2, fn run_index ->
        run_suffix = "#{suffix}-#{run_index}"

        %ToolRun{
          id: "run-#{run_suffix}",
          tool_call_id: "call-#{run_suffix}",
          tool: "bash",
          workspace: "/isolated/candidate",
          status: if(run_index == 1, do: :completed, else: :failed),
          arguments: %{"command" => text || "mix test"},
          result:
            if(run_index == 1,
              do: %{
                "output" => text || "A retained output preview",
                "truncated" => true,
                "metadata" => %{
                  "artifact_id" => "not-present-on-disk",
                  "artifact_bytes" => 100_000,
                  "artifact_complete" => false
                }
              }
            ),
          error: if(run_index == 2, do: %{"error" => text || "check failed"})
        }
      end)

    %Invocation{
      id: "invocation-#{suffix}",
      turn_id: turn.id,
      message_id: "report-#{suffix}",
      tool_runs: Map.new(runs, &{&1.id, &1}),
      tool_run_order: Enum.map(runs, & &1.id)
    }
  end

  defp report(findings),
    do:
      Jason.encode!(%{
        "summary" => "Evidence is limited",
        "limitations" => "Only selected terminal work is visible",
        "findings" => findings
      })

  defp finding(citations) do
    %{
      "observation" => "Repeated scope drift",
      "hypothesis" =>
        "Unclear acceptance criteria or new requirements; the first task did finish",
      "alternative" =>
        "Implement a per-task acceptance checklist to preserve the same scope requirement",
      "tradeoffs" => "Freezing scope improves focus but delays new requests",
      "experiment" => "Freeze one task's criteria and count subsequent scope changes",
      "uncertainty" => "The selected sample is small",
      "recurring" => true,
      "citations" => citations
    }
  end

  defp memory(index) do
    %{
      id: "memory-#{index}",
      project: "/workspace",
      kind: "decision",
      key: "scope-#{index}",
      value: "Bound the scope",
      active: rem(index, 2) == 0,
      created_at: Integer.to_string(index)
    }
  end

  defp history(count) do
    session = %Session{id: "session", workspace: "/workspace"}
    sibling = %Session{id: "sibling", workspace: session.workspace}
    outcomes = %{0 => :completed, 1 => :partial, 2 => :failed, 3 => :cancelled, 4 => :reworked}

    turns =
      Map.new(1..count, fn index ->
        id = "turn-#{index}"

        {id,
         %Turn{
           id: id,
           session_id: if(rem(index, 2) == 0, do: sibling.id, else: session.id),
           user_message_id: "message-#{index}",
           status: :terminal,
           outcome: Map.fetch!(outcomes, rem(index - 1, 5)),
           mode: :direct
         }}
      end)

    messages =
      Map.new(1..count, fn index ->
        id = "message-#{index}"
        {id, %Message{id: id, body: "Task #{index}", created_sequence: index}}
      end)

    {%Projection{
       sequence: count,
       sessions: %{session.id => session, sibling.id => sibling},
       turns: turns,
       messages: messages
     }, session}
  end
end
