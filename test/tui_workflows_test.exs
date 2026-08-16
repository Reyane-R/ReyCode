defmodule ReyCode.TUI.WorkflowsTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{Cancellation, Directive, GateReview, NewRoom, SquadStatus, Workspace}

  defmodule EngineStub do
    use GenServer

    def start_link(owner, replies), do: GenServer.start_link(__MODULE__, {owner, replies})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(message, _from, {owner, replies} = state) do
      send(owner, {:engine_call, message})
      {:reply, Map.fetch!(replies, elem(message, 0)), state}
    end
  end

  test "new room owns initial, input, submission, and cancellation state" do
    {:ok, engine} = EngineStub.start_link(self(), %{create_room: {:ok, "room-new"}})
    opened = NewRoom.open(term(engine: engine))

    assert opened.assigns.modal == :new_room
    assert opened.assigns.new_room == %{name: "", workspace: File.cwd!()}
    assert opened.focused == "new-room-name"

    assert {:noreply, submitted} = NewRoom.submit_value(opened, "Platform Work")
    assert_receive {:engine_call, {:create_room, "Platform Work", workspace}}
    assert workspace == File.cwd!()
    assert submitted.assigns.selected_room_id == "room-new"
    assert submitted.assigns.new_room == NewRoom.initial()
    assert submitted.assigns.modal == nil
    assert submitted.focused == "prompt"

    assert NewRoom.cancel(opened).assigns.new_room == NewRoom.initial()
  end

  test "cancellation targets the active turn and clears confirmation state" do
    {:ok, engine} = EngineStub.start_link(self(), %{cancel_turn: :ok})
    opened = term(engine: engine) |> with_turn(active_turn()) |> Cancellation.open()

    assert opened.assigns.modal == :cancel
    assert opened.assigns.cancel_turn_id == "turn-1"
    assert opened.assigns.slash == nil

    assert {:noreply, submitted} = Cancellation.submit(opened)
    assert_receive {:engine_call, {:cancel_turn, "turn-1", "Cancelled by user"}}
    assert submitted.assigns.cancel_turn_id == nil
    assert submitted.assigns.notice == "Turn cancelled"
    assert submitted.focused == "prompt"
  end

  test "directive opens only for the running squad and resets after submission" do
    {:ok, engine} = EngineStub.start_link(self(), %{add_squad_directive: :ok})
    opened = term(engine: engine) |> with_turn(active_turn()) |> Directive.open()

    assert opened.assigns.modal == :directive
    assert opened.assigns.directive == %{turn_id: "turn-1", text: ""}
    assert opened.focused == "directive-text"

    assert {:noreply, submitted} = Directive.submit_value(opened, "Keep scope narrow")
    assert_receive {:engine_call, {:add_squad_directive, "turn-1", "Keep scope narrow"}}
    assert submitted.assigns.directive == Directive.initial()
    assert submitted.assigns.notice == "Squad directive added"
    assert submitted.focused == "prompt"
  end

  test "gate review preserves decision order and shortcut submission" do
    {:ok, engine} = EngineStub.start_link(self(), %{resolve_gate: :ok})
    review = %{decision: :approve, reasons: []}
    turn = put_in(active_turn(), [:squad, :pending_review], review)
    opened = term(engine: engine) |> with_turn(turn) |> GateReview.open()

    assert GateReview.options() == [:approve, :rework, :abort]
    assert opened.assigns.gate_review == %{turn_id: "turn-1", review: review, index: 0}
    assert GateReview.move(opened, -1).assigns.gate_review.index == 2

    assert {:noreply, submitted} = GateReview.choose(opened, "R")
    assert_receive {:engine_call, {:resolve_gate, "turn-1", :rework, nil, []}}
    assert submitted.assigns.gate_review == GateReview.initial()
    assert submitted.assigns.notice == "Release returned for rework"
    assert submitted.focused == "prompt"
  end

  test "workspace open and close preserve the modal contract" do
    opened = Workspace.open(term())

    assert opened.assigns.modal == :workspace
    assert opened.assigns.slash == nil
    assert opened.assigns.notice == nil

    closed = Workspace.close(opened)
    assert closed.assigns.modal == nil
    assert closed.focused == "prompt"
  end

  test "squad status opens for a squad run and closes cleanly" do
    opened = term() |> with_turn(active_turn()) |> SquadStatus.open()

    assert opened.assigns.modal == :squad_dashboard
    assert opened.assigns.slash == nil

    closed = SquadStatus.close(opened)
    assert closed.assigns.modal == nil
    assert closed.assigns.notice == nil
    assert closed.focused == "prompt"
  end

  defp term(overrides \\ []) do
    room = %{id: "room-1", active_turn_id: nil}

    assigns = %{
      engine: nil,
      modal: nil,
      notice: nil,
      selected_room_id: "room-1",
      projection: %{rooms: %{"room-1" => room}, turns: %{}},
      slash: %{query: "/", index: 0, restore_draft: nil},
      cancel_turn_id: nil,
      directive: Directive.initial(),
      gate_review: GateReview.initial(),
      new_room: NewRoom.initial()
    }

    %Breeze.Term{assigns: Map.merge(assigns, Map.new(overrides))}
  end

  defp with_turn(term, turn) do
    term
    |> put_in([Access.key(:assigns), :projection, :rooms, "room-1", :active_turn_id], turn.id)
    |> put_in([Access.key(:assigns), :projection, :turns, turn.id], turn)
  end

  defp active_turn do
    %{
      id: "turn-1",
      room_id: "room-1",
      mode: :squad,
      status: :running,
      squad: %{pending_review: nil}
    }
  end
end
