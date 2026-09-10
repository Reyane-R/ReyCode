defmodule ReyCode.TUI.MergeReviewTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{MergeReview, Notice}

  defmodule DecisionRecorder do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call({:resolve_merge, child_id, decision}, _from, owner) do
      send(owner, {:decision, child_id, decision})
      {:reply, :ok, owner}
    end
  end

  defmodule ReviewView do
    use Breeze.View

    @impl true
    def mount(assigns, term), do: {:ok, assign(term, assigns)}
    @impl true
    def render(assigns), do: MergeReview.modal(%{term: assigns})
    @impl true
    def handle_event(:input, %{"key" => key}, term), do: MergeReview.handle_input(key, term)
  end

  setup do
    engine = start_supervised!({DecisionRecorder, self()})

    child = %{
      id: "child",
      participant: %{name: "Builder"},
      execution_context: %{isolation: %{"source_workspace" => "/workspace/source"}},
      pending_tool_review: %{arguments: %{"diff" => Enum.map_join(1..40, "\n", &"+line #{&1}")}}
    }

    term = %Breeze.Term{
      focused: "prompt",
      assigns: %{
        engine: engine,
        agent_hub: %{index: 3},
        projection: %{invocations: %{child.id => child}}
      }
    }

    %{term: MergeReview.open(term, child), child: child}
  end

  test "opening and submitting never implicitly choose Apply", %{term: term, child: child} do
    assert term.assigns.merge_review.decision == nil

    for submit <- [&MergeReview.submit/1, &MergeReview.handle_input("Enter", &1)] do
      assert {:noreply, unchanged} = submit.(term)
      assert unchanged.assigns.modal == :merge_review
      assert unchanged.assigns.merge_review == term.assigns.merge_review
      assert %Notice{severity: :info} = unchanged.assigns.notice
    end

    assert {:noreply, selected} = MergeReview.handle_input("ArrowLeft", term)
    assert MergeReview.open(selected, child).assigns.merge_review.decision == nil
    refute_received {:decision, _, _}
  end

  test "horizontal arrows choose without resolving and Enter confirms that choice", %{term: term} do
    for {key, decision} <- [{"ArrowLeft", :apply}, {"ArrowRight", :discard}] do
      assert {:noreply, selected} = MergeReview.handle_input(key, term)
      assert selected.assigns.merge_review.decision == decision
      refute_received {:decision, _, _}
      assert {:noreply, resolved} = MergeReview.handle_input("Enter", selected)
      assert_received {:decision, "child", ^decision}
      assert resolved.assigns.modal == :agent_hub
      assert resolved.assigns.merge_review == MergeReview.initial()
    end
  end

  test "Apply and Discard shortcuts act immediately without a selection", %{term: term} do
    for {key, decision} <- [{"a", :apply}, {"A", :apply}, {"d", :discard}, {"D", :discard}] do
      assert {:noreply, resolved} = MergeReview.handle_input(key, term)
      assert_received {:decision, "child", ^decision}
      assert %Notice{severity: :success} = resolved.assigns.notice
    end
  end

  test "scrolling preserves the choice and Escape preserves the underlying hub selection", %{
    term: term
  } do
    assert {:noreply, selected} = MergeReview.handle_input("ArrowRight", term)

    for {down, up} <- [{"j", "k"}, {"ArrowDown", "ArrowUp"}] do
      assert {:noreply, scrolled} = MergeReview.handle_input(down, selected)
      assert scrolled.assigns.merge_review.offset == 1
      assert scrolled.assigns.merge_review.decision == :discard
      assert {:noreply, restored} = MergeReview.handle_input(up, scrolled)
      assert restored.assigns.merge_review.offset == 0
    end

    assert {:noreply, closed} = MergeReview.handle_input("Escape", selected)
    assert closed.assigns.modal == :agent_hub
    assert closed.assigns.agent_hub == term.assigns.agent_hub
    assert closed.focused == "prompt"
    refute_received {:decision, _, _}
  end

  test "rendered review names the source, warns about effects, and marks the chosen action", %{
    term: term
  } do
    session = Breeze.Test.start!(ReviewView, size: {120, 24}, start_opts: term.assigns)
    on_exit(fn -> Breeze.Test.stop(session) end)

    screen = Breeze.Test.render!(session)
    assert screen =~ "Source workspace: /workspace/source"
    assert screen =~ "Apply modifies the source workspace"
    assert screen =~ "No action selected"
    refute screen =~ "[selected]"

    Breeze.Test.input(session, "ArrowLeft")
    assert Breeze.Test.render!(session) =~ "[selected] A Apply patch"
    Breeze.Test.input(session, "ArrowRight")
    screen = Breeze.Test.render!(session)
    assert screen =~ "[selected] D Discard patch"
    refute screen =~ "[selected] A Apply patch"
    refute_received {:decision, _, _}
  end
end
