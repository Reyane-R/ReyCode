defmodule ReyCode.TUI.AdvisorHubTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Invocation, Message, Participant, Projection, Session}
  alias ReyCode.TUI.{Advisor, AgentHub}

  test "finds only the configured Advisor task Participant" do
    advisor = %Participant{id: "advisor", name: "Advisor", kind: :task}
    primary = %Participant{id: "primary", name: "Advisor", kind: :primary}
    session = %Session{participants: [primary, advisor]}
    assert Advisor.advisor(session).id == "advisor"
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

    session = %Session{id: "room", participants: [advisor]}

    term = %Breeze.Term{
      assigns: %{
        projection: %Projection{sessions: %{"room" => session}},
        selected_session_id: "room",
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
    session = %Session{id: "room", participants: []}

    term = %Breeze.Term{
      assigns: %{
        projection: %Projection{sessions: %{"room" => session}},
        selected_session_id: "room",
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

    session = %Session{id: "room", message_order: ["parent-message", "child-message"]}

    projection = %Projection{
      sessions: %{"room" => session},
      messages: %{
        "parent-message" => %Message{id: "parent-message", invocation_id: "parent"},
        "child-message" => %Message{id: "child-message", invocation_id: "child"}
      },
      invocations: %{"parent" => parent, "child" => child}
    }

    term = %{assigns: %{projection: projection, selected_session_id: "room"}}

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

    session = %Session{id: "room", message_order: ["child-message"]}

    projection = %Projection{
      sessions: %{"room" => session},
      messages: %{"child-message" => %Message{id: "child-message", invocation_id: "child"}},
      invocations: %{"child" => child}
    }

    term = %Breeze.Term{
      assigns: %{
        projection: projection,
        selected_session_id: "room",
        agent_hub: AgentHub.initial(),
        breeze: %{terminal: %{width: 80}},
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
    assert {:noreply, inspected} = AgentHub.handle_input("Tab", term)
    assert inspected.assigns.agent_hub.panel == :inspector
    assert {:noreply, submitted} = AgentHub.submit(term)
    assert submitted.assigns.agent_hub.panel == :inspector
    assert {:noreply, scrolled} = AgentHub.handle_input("j", inspected)
    assert scrolled.assigns.agent_hub.offset == 0
    assert {:noreply, tree} = AgentHub.handle_input("T", term)
    assert tree.assigns.agent_hub.tree?
    assert {:noreply, roster} = AgentHub.handle_input("Escape", inspected)
    assert roster.assigns.agent_hub.panel == :roster
    assert {:noreply, ^term} = AgentHub.handle_input("unknown", term)
    assert {:noreply, entered} = AgentHub.handle_input("Enter", term)
    assert entered.assigns.agent_hub.panel == :inspector
    assert {:noreply, cancelled} = AgentHub.handle_input("c", term)
    assert cancelled.assigns.notice == "Child Invocation cancelled"
    assert_receive :cancelled
  end
end
