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
    assert item.target == "read approval required"
    assert Activity.text(item, "unused") == "Ⅱ · Paused · read approval required"
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
      message_order: ["msg-parent", "msg-child"]
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
      {projection, room_id, _invocation_id} =
        fixture(
          invocation_status: terminal_invocation_status(outcome),
          turn_status: :terminal,
          outcome: outcome
        )

      view = Activity.present(room_id, projection, %{}, @now_ms)

      refute Activity.active?(view)
      assert view.header.state == :terminal
      assert view.header.outcome == outcome
      assert Activity.text(view.header, "never") =~ view.header.label
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

    selected_room = %{Map.fetch!(projection.rooms, room_id) | message_order: ["msg-1", "msg-2"]}

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
