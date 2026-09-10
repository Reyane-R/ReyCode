defmodule ReyCode.TUI.VerificationUnavailableTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Session, VerifiedChange, VerifiedChangeResolution}
  alias ReyCode.TUI.{Cancellation, Verification}

  @message "Engine response unavailable; request may have been recorded. Inspect durable status; do not retry blindly."

  defmodule UnavailableEngine do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, Map.merge(opts, %{requests: [], recorded?: false})}
    @impl true
    def handle_call(:requests, _from, state), do: {:reply, state.requests, state}
    def handle_call(:snapshot, _from, %{failure: :malformed} = state), do: {:reply, %{}, state}

    def handle_call(:snapshot, _from, %{failure: :snapshot, recorded?: true} = state),
      do: {:stop, :normal, state}

    def handle_call(:snapshot, _from, state), do: {:reply, state.projection, state}

    def handle_call(
          {:start_verified_change, _source, _options, directory, _started_ms} = request,
          from,
          state
        ) do
      File.rmdir!(directory)
      record(request, from, state)
    end

    def handle_call(request, from, state), do: record(request, from, state)

    defp record(request, _from, state) do
      operation = elem(request, 0)
      send(state.owner, {:requested, operation})
      state = %{state | requests: [request | state.requests], recorded?: true}

      case state.failure do
        :request -> {:stop, :normal, state}
        :rejected -> {:reply, {:error, :rejected}, state}
        _ -> {:reply, {:ok, "receipt"}, state}
      end
    end
  end

  defmodule Surface do
    use Breeze.View
    alias ReyCode.TUI.Components.Modals
    @impl true
    def mount(opts, term), do: {:ok, term |> assign(opts.assigns) |> focus(opts.focused)}
    @impl true
    def render(%{modal: nil} = assigns), do: ~H"<box>Closed</box>"
    def render(assigns), do: Modals.active(%{term: assigns})
    @impl true
    def handle_event(event, payload, term), do: ReyCode.TUI.handle_event(event, payload, term)
    @impl true
    def handle_info({:engine_restarted, engine}, term),
      do: {:noreply, assign(term, engine: engine)}
  end

  test "start request exit and success followed by snapshot exit preserve the complete setup" do
    for failure <- [:request, :snapshot, :dead] do
      term = term(nil, failure) |> Verification.open()

      {:noreply, term} =
        Verification.handle_event("verify_commands_changed", %{value: "true"}, term)

      term = term |> Verification.focus() |> Verification.focus()
      surface = surface(term)
      Breeze.Test.input(surface, "Enter")
      failed = Breeze.Test.metadata(surface)
      assert_preserved(term, failed, term.focused)
      assert failed.assigns.verification.response_uncertain?
      assert failed.assigns.verification.goal == term.assigns.verification.goal
      assert failed.assigns.verification.commands == "true"
      if failure != :dead, do: assert_received({:requested, :start_verified_change})
      refute failed.assigns.notice.message =~ "Could not start"
      assert Breeze.Test.render!(surface) =~ "do not retry blindly"

      replacement = engine(term.assigns.projection, :rejected)
      Breeze.Test.info(surface, {:engine_restarted, replacement})

      for key <- ["Enter", " ", %{"ctrlKey" => true, "key" => "s"}],
          do: Breeze.Test.input(surface, key)

      assert GenServer.call(replacement, :requests) == []
      Breeze.Test.input(surface, "Escape")
      assert Breeze.Test.metadata(surface).assigns.modal == nil
      reopened = Verification.open(%{term | assigns: failed.assigns})
      refute reopened.assigns.verification.response_uncertain?
    end
  end

  test "Apply, Discard and Reconcile exits retain review evidence and lock all mutation paths" do
    for {key, resolution} <- [
          {"a", nil},
          {"d", nil},
          {"r", %VerifiedChangeResolution{status: :indeterminate}}
        ],
        failure <- [:request, :snapshot, :dead] do
      term = term(resolution, failure) |> Verification.review()
      {:noreply, term} = Verification.handle_input("3", term)
      {:noreply, term} = Verification.handle_input("ArrowDown", term)
      surface = surface(term)
      Breeze.Test.input(surface, key)
      focused = Breeze.Test.metadata(surface).focused
      Breeze.Test.input(surface, "Enter")
      failed = Breeze.Test.metadata(surface)
      assert_preserved(term, failed, focused)
      assert failed.assigns.verification.response_uncertain?
      assert failed.assigns.verification.decision == nil
      assert failed.assigns.verification.tab == :patch
      assert failed.assigns.verification.offset == term.assigns.verification.offset
      assert failed.assigns.verification.patch_hash == "hash"
      assert Breeze.Test.render!(surface) =~ "do not retry blindly"
      assert Breeze.Test.render!(surface) =~ "status unconfirmed"
      refute Breeze.Test.render!(surface) =~ "Source not applied by ReyCode"
      replacement = engine(term.assigns.projection, :rejected)
      Breeze.Test.info(surface, {:engine_restarted, replacement})

      for key <- ["a", "d", "r", "e", "Enter", "4", "PageDown", "Enter"],
          do: Breeze.Test.input(surface, key)

      assert GenServer.call(replacement, :requests) == []
      assert Breeze.Test.metadata(surface).assigns.notice.message == @message
      Breeze.Test.input(surface, "Escape")
      assert Breeze.Test.metadata(surface).assigns.modal == nil
      refute Verification.review(term).assigns.verification.response_uncertain?
    end
  end

  test "an uncertain revision setup cannot evade its lock by returning to the parent review" do
    term = term(nil, :request) |> Verification.review()
    {:noreply, term} = Verification.handle_input("e", term)
    term = term |> Verification.focus() |> Verification.focus()
    assert {:noreply, failed} = Verification.submit(term)
    assert failed.focused == term.focused
    assert failed.assigns.verification.response_uncertain?
    assert {:noreply, review} = Verification.handle_input("Escape", failed)
    assert review.assigns.verification.mode == :review
    assert review.assigns.verification.response_uncertain?
    assert {:noreply, locked} = Verification.handle_input("e", review)
    assert locked.assigns.verification.mode == :review
    assert locked.assigns.notice.message == @message
  end

  test "cancel exit preserves modal and focus and cannot retry after the engine restarts" do
    for failure <- [:request, :dead] do
      term = term(nil, failure)
      term = put_in(term.assigns.projection.sessions["source"].verified_change.phase, "baseline")
      term = Cancellation.open(term)
      surface = surface(term)
      focused = Breeze.Test.metadata(surface).focused
      Breeze.Test.input(surface, "Enter")
      failed = Breeze.Test.metadata(surface)
      assert_preserved(term, failed, focused)
      assert failed.assigns.cancel_response_uncertain?
      assert Breeze.Test.render!(surface) =~ "do not retry blindly"
      replacement = engine(term.assigns.projection, :rejected)
      Breeze.Test.info(surface, {:engine_restarted, replacement})
      Breeze.Test.input(surface, "Enter")
      assert GenServer.call(replacement, :requests) == []
      Breeze.Test.input(surface, "Escape")
      assert Breeze.Test.metadata(surface).assigns.modal == nil

      refute Cancellation.open(%{term | assigns: failed.assigns}).assigns.cancel_response_uncertain?
    end
  end

  test "tagged rejection remains an ordinary error and logic errors are not rescued" do
    term = term(nil, :rejected) |> Verification.review()
    {:noreply, selected} = Verification.handle_input("a", term)
    assert {:noreply, rejected} = Verification.submit(selected)
    refute rejected.assigns.verification.response_uncertain?
    assert rejected.assigns.notice.message =~ "Resolution failed"

    term = term(nil, :malformed) |> Verification.open()

    {:noreply, term} =
      Verification.handle_event("verify_commands_changed", %{value: "true"}, term)

    assert_raise KeyError, fn ->
      term |> Verification.focus() |> Verification.focus() |> Verification.submit()
    end
  end

  defp assert_preserved(term, metadata, focused) do
    assert metadata.assigns.modal == term.assigns.modal
    assert metadata.assigns.drafts == term.assigns.drafts
    assert metadata.assigns.selected_session_id == term.assigns.selected_session_id
    assert metadata.assigns.projection == term.assigns.projection
    assert metadata.focused == focused
    assert metadata.assigns.notice.message == @message
  end

  defp surface(term) do
    surface =
      Breeze.Test.start!(Surface,
        size: {60, 20},
        start_opts: %{assigns: term.assigns, focused: term.focused},
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(surface) end)
    Breeze.Test.render!(surface)
    surface
  end

  defp engine(projection, failure) do
    pid =
      start_supervised!(
        {UnavailableEngine, %{owner: self(), projection: projection, failure: failure}},
        id: make_ref(),
        restart: :temporary
      )

    if failure == :dead, do: GenServer.stop(pid)
    pid
  end

  defp term(resolution, failure) do
    change = %VerifiedChange{
      id: "change",
      phase: "ready",
      prompt: "original goal",
      commands: ["true"],
      source_workspace: System.tmp_dir!(),
      workspace: System.tmp_dir!(),
      baseline: [],
      checks: [],
      repair_count: 0,
      max_repair_count: 1,
      patch_hash: "hash",
      patch: "+one\n+two\n+three",
      timeout_ms: 600_000,
      check_timeout_ms: 120_000
    }

    session = %Session{
      id: "source",
      workspace: System.tmp_dir!(),
      verified_change: change,
      verified_change_resolution: resolution
    }

    projection = %{
      sequence: 1,
      sessions: %{"source" => session},
      session_order: ["source"],
      invocations: %{},
      turns: %{}
    }

    %Breeze.Term{
      focused: "prompt",
      assigns: %{
        engine: engine(projection, failure),
        projection: projection,
        selected_session_id: "source",
        drafts: %{"source" => "keep my draft"},
        modal: nil,
        slash: nil,
        home: false,
        notice: nil,
        breeze: %{terminal: %{width: 60, height: 20}}
      }
    }
  end
end
