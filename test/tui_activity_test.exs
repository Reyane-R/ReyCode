defmodule ReyCode.TUI.ActivityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.Orchestration.{Invocation, Participant, Projection, Room, ToolRun, Turn}
  alias ReyCode.TUI.Activity

  @now_ms DateTime.to_unix(~U[2026-08-26 22:00:10Z], :millisecond)
  @workspace "/workspace"

  test "provider thinking is active and elapsed from the durable Turn" do
    {projection, room_id, invocation_id} = fixture(invocation_status: :running)
    view = Activity.present(room_id, projection, %{}, @now_ms)
    item = Activity.invocation(view, invocation_id)

    assert Activity.active?(view)
    assert view.header == item
    assert item.state == :active
    assert item.label == "Thinking"
    assert item.target == "Assistant"
    assert item.elapsed_seconds == 10
    assert Activity.text(item, "⠋") == "⠋ · Thinking · Assistant · 10s"
  end

  test "running tool wins over thinking and owner approval wins over generic activity" do
    run = tool_run("run-1", :read, :running, %{"path" => "/workspace/lib/file.ex"})
    {projection, room_id, invocation_id} = fixture(invocation_status: :running, tool_runs: [run])
    view = Activity.present(room_id, projection, %{}, @now_ms)
    item = Activity.invocation(view, invocation_id)

    assert item.label == "Reading"
    assert item.target == "lib/file.ex"
    assert item.priority == 80

    waiting = %{run | status: :awaiting_approval}

    {projection, room_id, invocation_id} =
      fixture(invocation_status: :waiting_tool_approval, tool_runs: [waiting])

    view = Activity.present(room_id, projection, %{}, @now_ms)
    item = Activity.invocation(view, invocation_id)

    refute Activity.active?(view)
    assert item.state == :blocked
    assert item.label == "Paused"
    assert item.target == "read approval required · /tools"
    assert Activity.text(item, "unused") == "Ⅱ · Paused · read approval required · /tools"

    ready = %{run | status: :ready}

    {projection, room_id, invocation_id} =
      fixture(invocation_status: :running, tool_runs: [ready])

    view = Activity.present(room_id, projection, %{}, @now_ms)
    item = Activity.invocation(view, invocation_id)
    refute Activity.active?(view)
    assert item.state == :queued
    assert item.label == "Queued"
  end

  test "retry and active delegation use deterministic priority" do
    {projection, room_id, invocation_id} = fixture(invocation_status: :running, attempt: 2)
    view = Activity.present(room_id, projection, %{}, @now_ms)
    assert Activity.invocation(view, invocation_id).label == "Retrying"

    participant = participant("luna", "Luna", :task)

    run = %ToolRun{
      id: "spawn-1",
      tool: "spawn_task",
      status: :running,
      arguments: %{"agent" => "Luna"},
      child_invocation_id: "child"
    }

    parent = %Invocation{
      id: "parent",
      room_id: "room",
      turn_id: "turn",
      message_id: "msg-parent",
      participant: participant("assistant", "Assistant", :primary),
      status: :awaiting_delegation,
      tool_runs: %{run.id => run},
      tool_run_order: [run.id]
    }

    child = %Invocation{
      id: "child",
      room_id: "room",
      turn_id: "turn",
      message_id: "msg-child",
      participant: participant,
      status: :running,
      tool_runs: %{},
      tool_run_order: []
    }

    turn = %Turn{
      id: "turn",
      room_id: "room",
      status: :running,
      invocation_order: [parent.id, child.id],
      created_at: "2026-08-26T22:00:00Z"
    }

    room = %Room{
      id: "room",
      workspace: @workspace,
      participants: [parent.participant, participant],
      active_turn_id: turn.id,
      message_order: ["msg-child", "msg-parent"]
    }

    projection = %Projection{
      rooms: %{room.id => room},
      room_order: [room.id],
      turns: %{turn.id => turn},
      invocations: %{parent.id => parent, child.id => child},
      messages: %{
        "msg-parent" => %{
          invocation_id: parent.id,
          turn_id: turn.id,
          created_at: "2026-08-26T22:00:01Z"
        },
        "msg-child" => %{
          invocation_id: child.id,
          turn_id: turn.id,
          created_at: "2026-08-26T22:00:05Z"
        }
      }
    }

    view = Activity.present(room.id, projection, %{}, @now_ms)
    assert view.ordered_invocation_ids == [parent.id, child.id]
    assert view.header.label == "Delegating"
    assert view.header.target == "Luna"
    assert view.header.elapsed_seconds == 5
    assert Activity.invocation(view, child.id).label == "Thinking"
  end

  test "tool label matrix and target formatting are bounded and safe" do
    cases = [
      {:read, %{"path" => "/workspace/lib/a.ex"}, "Reading", "lib/a.ex"},
      {:grep, %{"pattern" => "needle"}, "Searching", "needle"},
      {:glob, %{"path" => "lib"}, "Scanning", "lib"},
      {:list, %{"path" => "test"}, "Scanning", "test"},
      {:bash, %{"command" => "mix test\n--trace"}, "Running", "mix test --trace"},
      {:edit, %{"path" => "lib/a.ex"}, "Editing", "lib/a.ex"},
      {:write, %{"path" => "README.md"}, "Writing", "README.md"},
      {:spawn_task, %{"agent" => "Luna"}, "Delegating", "Luna"}
    ]

    Enum.each(cases, fn {tool, arguments, label, target} ->
      item =
        Activity.tool(tool_run("run-#{tool}", tool, :running, arguments), @workspace, @now_ms)

      assert item.label == label
      assert item.target == target
      assert item.active?
    end)

    outside =
      Activity.tool(
        tool_run("outside", :read, :running, %{"path" => "/private/key"}),
        @workspace,
        @now_ms
      )

    assert outside.target == "<outside workspace>"

    root_workspace =
      Activity.tool(
        tool_run("root", :read, :running, %{"path" => "/tmp/file"}),
        "/",
        @now_ms
      )

    assert root_workspace.target == "tmp/file"

    bounded =
      Activity.tool(
        tool_run("bounded", :bash, :running, %{"command" => String.duplicate("é", 100)}),
        @workspace,
        @now_ms,
        target_graphemes: 12
      )

    assert String.length(bounded.target) == 12
    assert String.valid?(bounded.target)

    malformed = Activity.tool(tool_run("missing", :read, :running, %{}), @workspace, @now_ms)
    assert malformed.target == nil
  end

  property "every supported terminal Outcome is stable and inactive" do
    check all(outcome <- member_of([:completed, :partial, :reworked, :failed, :cancelled])) do
      invocation_status = terminal_invocation_status(outcome)

      {projection, room_id, invocation_id} =
        fixture(
          invocation_status: invocation_status,
          turn_status: :terminal,
          outcome: outcome
        )

      view = Activity.present(room_id, projection, %{}, @now_ms)

      refute Activity.active?(view)
      assert view.header.state == :terminal
      assert view.header.outcome == outcome
      assert Activity.text(view.header, "never") =~ view.header.label

      invocation_item = Activity.invocation(view, invocation_id)
      assert invocation_item.outcome == invocation_status
    end
  end

  test "selected Session scope ignores malformed hidden history and keeps parallel order" do
    {projection, room_id, first_id} = fixture(invocation_status: :running)
    second_id = "inv-2"

    second = %Invocation{
      id: second_id,
      room_id: room_id,
      turn_id: "turn",
      message_id: "msg-2",
      participant: participant("review", "Review", :task),
      status: :running,
      tool_runs: %{},
      tool_run_order: []
    }

    selected_room = %{Map.fetch!(projection.rooms, room_id) | message_order: ["msg-2", "msg-1"]}

    selected_turn = %{
      Map.fetch!(projection.turns, "turn")
      | invocation_order: [first_id, second_id]
    }

    hidden_room = %Room{id: "hidden", workspace: "/hidden", message_order: ["missing-message"]}

    projection = %{
      projection
      | rooms:
          projection.rooms |> Map.put(room_id, selected_room) |> Map.put("hidden", hidden_room),
        room_order: projection.room_order ++ ["hidden"],
        turns: Map.put(projection.turns, "turn", selected_turn),
        invocations: Map.put(projection.invocations, second_id, second),
        messages:
          Map.put(projection.messages, "msg-2", %{
            invocation_id: second_id,
            turn_id: "turn",
            created_at: "2026-08-26T22:00:02Z"
          })
    }

    view = Activity.present(room_id, projection, %{}, @now_ms)

    assert view.ordered_invocation_ids == [first_id, second_id]
    assert view.header.id == first_id
    assert map_size(view.invocation_items) == 2
  end

  test "nil/missing selection and provider/queue header states are explicit" do
    assert Activity.present(nil, %Projection{}, %{}, @now_ms) == %Activity.View{}
    assert Activity.present("missing", %Projection{}, %{}, @now_ms) == %Activity.View{}

    {projection, room_id, _invocation_id} = fixture(turn_status: :terminal, outcome: :completed)

    room = %{
      Map.fetch!(projection.rooms, room_id)
      | message_order: [],
        queued_turn_ids: ["queued"]
    }

    projection = %{projection | rooms: Map.put(projection.rooms, room_id, room)}
    assert Activity.present(room_id, projection, %{}, @now_ms).header.state == :queued

    room = %{room | queued_turn_ids: [], participants: []}
    projection = %{projection | rooms: Map.put(projection.rooms, room_id, room)}
    assert Activity.present(room_id, projection, %{}, @now_ms).header.label == "Model required"

    primary = participant("assistant", "Assistant", :primary)
    room = %{room | participants: [primary]}
    projection = %{projection | rooms: Map.put(projection.rooms, room_id, room)}

    checking = %{simulator: %{status: :checking}}

    assert Activity.present(room_id, projection, checking, @now_ms).header.label ==
             "Checking provider"

    assert Activity.present(room_id, projection, checking, @now_ms).active?

    configured = %{
      simulator: %{id: :simulator, status: :configured, models: [], credential_count: 0}
    }

    ready = Activity.present(room_id, projection, configured, @now_ms).header
    assert ready.state == :idle
    assert Activity.text(ready, "unused") == "• · Ready"

    assert Activity.present(room_id, projection, %{simulator: %{status: :error}}, @now_ms).header.label ==
             "Provider unavailable"

    cases = [
      {:ready, :queued, "Queued"},
      {:requested, :queued, "Queued"},
      {:completed, :terminal, "Read"},
      {:failed, :terminal, "Failed"},
      {:denied, :terminal, "Denied"},
      {:interrupted, :terminal, "Interrupted"},
      {:unknown, :idle, "Read"}
    ]

    Enum.each(cases, fn {status, state, label} ->
      item =
        Activity.tool(
          tool_run("run-#{status}", :read, status, %{"path" => "file"}),
          @workspace,
          @now_ms
        )

      assert item.state == state
      assert item.label == label
    end)

    denied =
      Activity.tool(
        tool_run("denied-bash", :bash, :denied, %{"command" => "mix test"}),
        @workspace,
        @now_ms
      )

    assert Activity.text(denied, "unused") == "× · Denied · Bash · mix test"

    interrupted =
      Activity.tool(
        tool_run("interrupted-bash", :bash, :interrupted, %{"command" => "mix test"}),
        @workspace,
        @now_ms
      )

    assert Activity.text(interrupted, "unused") == "× · Interrupted · Bash · mix test"

    unknown =
      Activity.tool(
        tool_run("unknown-tool", :custom_tool, :running, %{z: "value"}),
        @workspace,
        @now_ms
      )

    assert unknown.label == "Working"
    assert unknown.target == "z=value"

    no_arguments =
      Activity.tool(
        %ToolRun{id: "none", tool: :custom_tool, status: :running},
        @workspace,
        @now_ms
      )

    assert no_arguments.target == nil

    date_started = %{
      tool_run("date", :bash, :running, %{"command" => "echo ok"})
      | started_at: ~U[2026-08-26 22:00:05Z]
    }

    assert Activity.tool(date_started, @workspace, @now_ms).elapsed_seconds == 5
  end

  test "waiting invocation without a run and delegation without a child are blocked, not active" do
    {projection, room_id, invocation_id} = fixture(invocation_status: :waiting_tool_approval)
    view = Activity.present(room_id, projection, %{}, @now_ms)
    item = Activity.invocation(view, invocation_id)
    assert item.state == :blocked
    assert item.target == "tool approval required · /tools"
    refute Activity.active?(view)

    {projection, room_id, invocation_id} = fixture(invocation_status: :awaiting_delegation)
    view = Activity.present(room_id, projection, %{}, @now_ms)
    item = Activity.invocation(view, invocation_id)
    assert item.state == :blocked
    assert item.label == "Paused"
  end

  test "room header selects the newest terminal Turn from newest-first message order" do
    {projection, room_id, _invocation_id} =
      fixture(invocation_status: :completed, turn_status: :terminal, outcome: :completed)

    newest_turn = %Turn{
      id: "turn-newest",
      room_id: room_id,
      status: :terminal,
      outcome: :failed,
      invocation_order: [],
      created_at: "2026-08-26T22:00:09Z"
    }

    room = %{
      Map.fetch!(projection.rooms, room_id)
      | message_order: ["msg-newest", "msg-1"]
    }

    projection = %{
      projection
      | rooms: Map.put(projection.rooms, room_id, room),
        turns: Map.put(projection.turns, newest_turn.id, newest_turn),
        messages:
          Map.put(projection.messages, "msg-newest", %{
            invocation_id: nil,
            turn_id: newest_turn.id
          })
    }

    view = Activity.present(room_id, projection, %{}, @now_ms)
    assert view.header.outcome == :failed
    assert view.header.label == "Failed"
  end

  test "selected activity view keeps a bounded newest invocation window" do
    {projection, room_id, _invocation_id} = fixture(invocation_status: :completed)

    {message_order, messages, invocations} =
      Enum.reduce(1..300, {[], %{}, %{}}, fn index, {order, message_acc, invocation_acc} ->
        invocation_id = "bulk-inv-#{index}"
        message_id = "bulk-msg-#{index}"

        invocation = %Invocation{
          id: invocation_id,
          room_id: room_id,
          turn_id: "turn",
          message_id: message_id,
          participant: participant("p-#{index}", "P#{index}", :task),
          status: :completed
        }

        {
          [message_id | order],
          Map.put(message_acc, message_id, %{invocation_id: invocation_id, turn_id: "turn"}),
          Map.put(invocation_acc, invocation_id, invocation)
        }
      end)

    room = %{Map.fetch!(projection.rooms, room_id) | message_order: message_order}

    projection = %{
      projection
      | rooms: Map.put(projection.rooms, room_id, room),
        messages: messages,
        invocations: invocations
    }

    view = Activity.present(room_id, projection, %{}, @now_ms)
    assert length(view.ordered_invocation_ids) == 256
    assert view.truncated?
    assert List.first(view.ordered_invocation_ids) == "bulk-inv-45"
  end

  test "theme terminal glyphs are distinct for every supported Outcome" do
    glyphs =
      Enum.map([:completed, :partial, :reworked, :failed, :cancelled], fn outcome ->
        ReyCode.Theme.activity_outcome_glyph(outcome)
      end)

    assert length(Enum.uniq(glyphs)) == 5
    assert ReyCode.Theme.activity_outcome_glyph(:unknown) == "·"
    assert ReyCode.Theme.activity_idle_glyph() == "•"
  end

  test "presentation fallbacks are bounded, static, and fail closed" do
    assert Activity.text(nil, "frame") == ""

    failed = %Activity.Item{
      id: "failed",
      kind: :turn,
      state: :terminal,
      label: "Failed",
      outcome: :failed,
      active?: false,
      priority: 0
    }

    partial = %{failed | id: "partial", label: "Partial", outcome: :partial}
    assert Activity.color(failed) == "error"
    assert Activity.color(partial) == "warning"
    assert Activity.color(nil) == "muted"

    {projection, room_id, invocation_id} = fixture(invocation_status: :unknown)

    item =
      projection
      |> then(&Activity.present(room_id, &1, %{}, @now_ms))
      |> Activity.invocation(invocation_id)

    assert item.state == :idle
    assert Activity.text(item, "unused") == "• · Ready"

    nonbinary_path =
      Activity.tool(tool_run("number", :read, :running, %{"path" => 42}), @workspace, @now_ms)

    assert nonbinary_path.target == "42"

    empty =
      Activity.tool(tool_run("empty", :custom, :running, %{}), @workspace, @now_ms,
        target_graphemes: 0
      )

    assert empty.target == nil
  end

  defp fixture(opts) do
    room_id = "room"
    turn_id = "turn"
    invocation_id = "inv-1"
    outcome = Keyword.get(opts, :outcome)
    turn_status = Keyword.get(opts, :turn_status, :running)
    invocation_status = Keyword.get(opts, :invocation_status, :running)
    runs = Keyword.get(opts, :tool_runs, [])

    participant = participant("assistant", "Assistant", :primary)

    invocation = %Invocation{
      id: invocation_id,
      room_id: room_id,
      turn_id: turn_id,
      message_id: "msg-1",
      participant: participant,
      status: invocation_status,
      attempt: Keyword.get(opts, :attempt, 1),
      tool_runs: Map.new(runs, &{&1.id, &1}),
      tool_run_order: Enum.map(runs, & &1.id)
    }

    turn = %Turn{
      id: turn_id,
      room_id: room_id,
      status: turn_status,
      outcome: outcome,
      invocation_order: [invocation_id],
      created_at: "2026-08-26T22:00:00Z"
    }

    room = %Room{
      id: room_id,
      workspace: @workspace,
      participants: [participant],
      active_turn_id: if(turn_status == :running, do: turn_id),
      message_order: ["msg-1"]
    }

    projection = %Projection{
      rooms: %{room_id => room},
      room_order: [room_id],
      turns: %{turn_id => turn},
      invocations: %{invocation_id => invocation},
      messages: %{
        "msg-1" => %{
          invocation_id: invocation_id,
          turn_id: turn_id,
          created_at: "2026-08-26T22:00:01Z"
        }
      }
    }

    {projection, room_id, invocation_id}
  end

  defp participant(id, name, kind) do
    %Participant{
      id: id,
      name: name,
      perspective: "test",
      provider: :simulator,
      model: nil,
      kind: kind
    }
  end

  defp tool_run(id, tool, status, arguments) do
    %ToolRun{
      id: id,
      tool: tool,
      status: status,
      arguments: arguments,
      workspace: @workspace,
      requested_at: "2026-08-26T22:00:00Z",
      started_at: "2026-08-26T22:00:05Z"
    }
  end

  defp terminal_invocation_status(:failed), do: :failed
  defp terminal_invocation_status(:cancelled), do: :cancelled
  defp terminal_invocation_status(_outcome), do: :completed
end
