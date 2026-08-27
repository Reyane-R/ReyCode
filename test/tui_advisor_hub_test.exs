defmodule ReyCode.TUI.AdvisorHubTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Invocation, Message, Participant, Projection, Room}
  alias ReyCode.TUI.{Advisor, AgentHub}

  test "finds only the configured Advisor task Participant" do
    advisor = %Participant{id: "advisor", name: "Advisor", kind: :task}
    primary = %Participant{id: "primary", name: "Advisor", kind: :primary}
    room = %Room{participants: [primary, advisor]}
    assert Advisor.advisor(room).id == "advisor"
    assert Advisor.advisor(nil) == nil
  end

  test "queues explicit Advisor review through the injected engine seam" do
    advisor = %Participant{
      id: "advisor",
      name: "Advisor",
      kind: :task,
      provider: :simulator,
      model: "test"
    }

    room = %Room{id: "room", participants: [advisor]}

    term = %Breeze.Term{
      assigns: %{
        projection: %Projection{rooms: %{"room" => room}},
        selected_room_id: "room",
        advisor_delegate: fn _room_id, _participant_id, brief, _engine ->
          send(self(), {:advisor_brief, brief})
          {:ok, "turn"}
        end,
        engine: self(),
        modal: :slash,
        slash: nil,
        notice: nil
      }
    }

    assert {:noreply, result} = Advisor.run(term, "Review the diff")
    assert result.assigns.notice == "Advisor review queued"
    assert_receive {:advisor_brief, "Review the diff"}
  end

  test "reports missing Advisor configuration" do
    room = %Room{id: "room", participants: []}

    term = %Breeze.Term{
      assigns: %{
        projection: %Projection{rooms: %{"room" => room}},
        selected_room_id: "room",
        modal: :slash,
        slash: nil,
        notice: nil
      }
    }

    assert {:noreply, result} = Advisor.run(term)
    assert result.assigns.notice =~ "Create a task Participant named Advisor"
  end

  test "Agent Hub scopes rows to delegated child Invocations" do
    child = %Invocation{
      id: "child",
      turn_id: "turn",
      delegated_from_invocation_id: "parent",
      participant: %Participant{name: "Luna"},
      label: "task",
      status: :running
    }

    parent = %Invocation{
      id: "parent",
      turn_id: "turn",
      participant: %Participant{name: "Assistant"},
      label: "task",
      status: :running
    }

    room = %Room{id: "room", message_order: ["parent-message", "child-message"]}

    projection = %Projection{
      rooms: %{"room" => room},
      messages: %{
        "parent-message" => %Message{id: "parent-message", invocation_id: "parent"},
        "child-message" => %Message{id: "child-message", invocation_id: "child"}
      },
      invocations: %{"parent" => parent, "child" => child}
    }

    term = %{assigns: %{projection: projection, selected_room_id: "room"}}

    assert [^child] = AgentHub.children(term)
  end

  test "Agent Hub cycles and cancels a selected child" do
    child = %Invocation{
      id: "child",
      turn_id: "turn",
      delegated_from_invocation_id: "parent",
      participant: %Participant{name: "Luna"},
      label: "task",
      status: :running
    }

    room = %Room{id: "room", message_order: ["child-message"]}

    projection = %Projection{
      rooms: %{"room" => room},
      messages: %{"child-message" => %Message{id: "child-message", invocation_id: "child"}},
      invocations: %{"child" => child}
    }

    term = %Breeze.Term{
      assigns: %{
        projection: projection,
        selected_room_id: "room",
        agent_hub: %{index: 0},
        engine: self(),
        cancel_child: fn "turn", _reason, _engine ->
          send(self(), :cancelled)
          :ok
        end,
        modal: :agent_hub,
        notice: nil
      }
    }

    assert {:noreply, next} = AgentHub.handle_input("ArrowDown", term)
    assert next.assigns.agent_hub.index == 0
    assert {:noreply, cancelled} = AgentHub.handle_input("c", term)
    assert cancelled.assigns.notice == "Child Invocation cancelled"
    assert_receive :cancelled
  end
end
