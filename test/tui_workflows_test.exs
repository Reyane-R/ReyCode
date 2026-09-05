defmodule ReyCode.TUI.WorkflowsTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{Cancellation, Notice, Workspace}

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

  test "cancellation targets the active turn and clears confirmation state" do
    {:ok, engine} = EngineStub.start_link(self(), %{cancel_turn: :ok})
    opened = term(engine: engine) |> with_turn(active_turn()) |> Cancellation.open()

    assert opened.assigns.modal == :cancel
    assert opened.assigns.cancel_turn_id == "turn-1"
    assert opened.assigns.slash == nil

    assert {:noreply, submitted} = Cancellation.submit(opened)
    assert_receive {:engine_call, {:cancel_turn, "turn-1", "Cancelled by user"}}
    assert submitted.assigns.cancel_turn_id == nil
    assert %Notice{severity: :success} = submitted.assigns.notice
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

  defp term(overrides \\ []) do
    session = %{id: "room-1", active_turn_id: nil}

    assigns = %{
      engine: nil,
      modal: nil,
      notice: nil,
      selected_session_id: "room-1",
      projection: %{sessions: %{"room-1" => session}, turns: %{}},
      slash: %{query: "/", index: 0, restore_draft: nil},
      cancel_turn_id: nil
    }

    %Breeze.Term{assigns: Map.merge(assigns, Map.new(overrides))}
  end

  defp with_turn(term, turn) do
    term
    |> put_in([Access.key(:assigns), :projection, :sessions, "room-1", :active_turn_id], turn.id)
    |> put_in([Access.key(:assigns), :projection, :turns, turn.id], turn)
  end

  defp active_turn do
    %{
      id: "turn-1",
      session_id: "room-1",
      mode: :squad,
      status: :running,
      squad: nil
    }
  end
end
