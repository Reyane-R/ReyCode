defmodule ReyCode.TUI.VerificationTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Session, VerifiedChange, VerifiedChangeResolution}
  alias ReyCode.TUI.{Cancellation, SlashPalette, State, Verification}

  defmodule Surface do
    use Breeze.View
    @impl true
    def mount(assigns, term) do
      term = assign(term, assigns)

      {:ok,
       focus(term, if(assigns.verification.mode == :setup, do: "verify-goal", else: "prompt"))}
    end

    @impl true
    def render(%{modal: nil} = assigns), do: ~H"<box>Session {@selected_session_id}</box>"
    def render(assigns), do: Verification.modal(%{term: assigns})
    @impl true
    def handle_event(event, payload, term), do: ReyCode.TUI.handle_event(event, payload, term)
  end

  defmodule Recorder do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, opts}
    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state.projection, state}

    def handle_call(
          {:start_verified_change, source_id, options, directory, _started_ms},
          _from,
          state
        ) do
      File.rmdir!(directory)
      send(state.owner, {:started, source_id, options})
      session = %Session{id: "new", workspace: directory, verified_change: record(options)}

      projection = %{
        state.projection
        | sequence: 2,
          sessions: Map.put(state.projection.sessions, "new", session),
          session_order: ["source", "new"]
      }

      {:reply, {:ok, "new"}, %{state | projection: projection}}
    end

    def handle_call({:cancel_verified_change, session_id}, _from, state) do
      send(state.owner, {:cancelled, session_id})
      {:reply, :ok, state}
    end

    defp record(options),
      do:
        struct!(
          VerifiedChange,
          Map.merge(options, %{
            id: "new-change",
            phase: "preparing",
            repair_count: 0,
            baseline: [],
            checks: []
          })
        )
  end

  setup do
    source = %Session{id: "source", workspace: System.tmp_dir!()}

    projection = %{
      sequence: 1,
      sessions: %{"source" => source},
      session_order: ["source"],
      invocations: %{},
      turns: %{},
      messages: %{}
    }

    engine = start_supervised!({Recorder, %{owner: self(), projection: projection}})

    term = %Breeze.Term{
      focused: "timeline-source",
      assigns: %{
        engine: engine,
        projection: projection,
        selected_session_id: "source",
        drafts: %{"source" => "original draft"},
        modal: nil,
        slash: nil,
        home: false,
        notice: nil,
        breeze: %{terminal: %{width: 80, height: 24}}
      }
    }

    %{term: term}
  end

  test "setup preserves draft and focus on cancel; default submission cannot authorize", %{
    term: term
  } do
    opened = Verification.open(term)
    assert opened.assigns.verification.goal == "original draft"
    assert {:noreply, unchanged} = Verification.submit(opened)
    assert unchanged.assigns.modal == :verification
    refute_received {:started, _, _}
    assert {:noreply, closed} = Verification.handle_input("Escape", unchanged)
    assert closed.assigns.drafts == term.assigns.drafts
    assert closed.focused == term.focused
  end

  test "slash lifecycle preserves the prior draft and accepts an optional editable goal", %{
    term: term
  } do
    palette = SlashPalette.open(term)
    assert {:noreply, setup} = SlashPalette.run_typed(palette, "/verify")
    assert setup.assigns.verification.goal == "original draft"
    assert {:noreply, closed} = Verification.handle_input("Escape", setup)
    assert closed.assigns.drafts == term.assigns.drafts

    assert {:noreply, setup} = SlashPalette.run_typed(term, "/verify fix the parser")
    assert setup.assigns.verification.goal == "fix the parser"
    assert setup.assigns.drafts == term.assigns.drafts

    typed = term |> SlashPalette.open() |> SlashPalette.set_query("/verify fix the parser")
    assert {:noreply, setup_from_enter} = SlashPalette.execute_selected(typed)
    assert setup_from_enter.assigns.verification.goal == "fix the parser"
    assert setup_from_enter.assigns.drafts == term.assigns.drafts

    assert {:noreply, no_change} = SlashPalette.run_typed(term, "/changes")
    assert no_change.assigns.modal == nil
    assert no_change.assigns.notice.message =~ "No verified change"
  end

  test "explicit authorization starts from selected source with ordered checks and switches session",
       %{term: term} do
    setup = Verification.open(term)

    assert {:noreply, setup} =
             Verification.handle_event(
               "verify_commands_changed",
               %{value: "printf baseline\ntrue"},
               setup
             )

    assert {:noreply, started} =
             setup |> Verification.focus() |> Verification.focus() |> Verification.submit()

    assert_received {:started, "source",
                     %{
                       prompt: "original draft",
                       commands: ["printf baseline", "true"],
                       max_repair_count: 1,
                       timeout_ms: 600_000,
                       check_timeout_ms: 120_000
                     }}

    assert started.assigns.selected_session_id == "new"
    assert started.assigns.drafts["source"] == ""
    assert started.assigns.modal == nil
    assert started.focused == "prompt"
  end

  test "invalid check contract does not dispatch or clear the draft", %{term: term} do
    setup = term |> Verification.open() |> Verification.focus() |> Verification.focus()

    for commands <- [
          "",
          "   ",
          Enum.map_join(1..9, "\n", &"echo #{&1}"),
          String.duplicate("x", 4097)
        ] do
      {:noreply, edited} =
        Verification.handle_event("verify_commands_changed", %{value: commands}, setup)

      assert {:noreply, rejected} = Verification.submit(edited)
      assert rejected.assigns.modal == :verification
      assert rejected.assigns.drafts == term.assigns.drafts
      assert rejected.assigns.notice.severity == :warning
    end

    refute_received {:started, _, _}
  end

  test "review defaults to no decision, blocks stale evidence, and allows blocked discard selection",
       %{term: term} do
    term = with_change(term, change())
    opened = Verification.review(term)
    assert {:noreply, unchanged} = Verification.submit(opened)
    assert unchanged.assigns.verification.decision == nil
    assert {:noreply, selected} = Verification.handle_input("a", opened)
    assert selected.assigns.verification.decision == :apply
    stale = with_change(selected, %{change() | patch_hash: "different"})
    assert {:noreply, rejected} = Verification.submit(stale)
    assert rejected.assigns.notice.message =~ "Evidence or eligibility changed"
    assert rejected.assigns.verification.decision == nil

    blocked =
      term
      |> with_change(%{change() | phase: "blocked", patch_hash: nil})
      |> Verification.review()

    assert {:noreply, rejected} = Verification.handle_input("a", blocked)
    assert rejected.assigns.verification.decision == nil
    assert {:noreply, selected} = Verification.handle_input("d", blocked)
    assert selected.assigns.verification.decision == :discard
  end

  test "indeterminate offers only reconciliation; applied labels distinguish isolated checks", %{
    term: term
  } do
    term = with_change(term, change())

    resolution = %VerifiedChangeResolution{
      status: :indeterminate,
      decision: :apply,
      error: "interrupted"
    }

    term =
      put_in(term.assigns.projection.sessions["source"].verified_change_resolution, resolution)

    opened = Verification.review(term)
    assert {:noreply, rejected} = Verification.handle_input("a", opened)
    assert rejected.assigns.verification.decision == nil
    assert {:noreply, selected} = Verification.handle_input("r", opened)
    assert selected.assigns.verification.decision == :reconcile
    assert {:noreply, rejected} = Verification.handle_input("e", selected)
    assert rejected.assigns.verification.mode == :review
    assert rejected.assigns.notice.message =~ "Finish or reconcile"
    assert Verification.source_label(term.assigns.projection.sessions["source"]) =~ "uncertain"

    applied = %{
      term.assigns.projection.sessions["source"]
      | verified_change_resolution: %{resolution | status: :applied}
    }

    assert Verification.summary(applied, term.assigns.projection) =~ "Applied"
    assert Verification.source_label(applied) =~ "not rerun after integration"
  end

  test "requested resolution cannot open revision setup", %{term: term} do
    term = with_change(term, change())

    term =
      put_in(
        term.assigns.projection.sessions["source"].verified_change_resolution,
        %VerifiedChangeResolution{status: :requested, decision: :apply}
      )

    opened = Verification.review(term)
    assert {:noreply, rejected} = Verification.handle_input("e", opened)
    assert rejected.assigns.verification.mode == :review
    assert rejected.assigns.notice.message =~ "Finish or reconcile"
  end

  test "whole verification cancellation works during baseline without a Turn", %{term: term} do
    term = with_change(term, %{change() | phase: "baseline"})
    assert term.assigns.projection.sessions["source"].active_turn_id == nil
    assert {:noreply, cancelled} = term |> Cancellation.open() |> Cancellation.submit()
    assert_received {:cancelled, "source"}
    assert cancelled.assigns.notice.message =~ "stopping"
    assert {:noreply, _term} = ReyCode.TUI.handle_event(:input, %{"key" => "Escape"}, term)
    assert_received {:cancelled, "source"}
  end

  test "a blocked journal never implies that host work has already stopped", %{term: term} do
    term = with_change(term, %{change() | phase: "blocked"})
    session = term.assigns.projection.sessions["source"]
    assert Verification.source_label(session) == "Blocked; host work may still be stopping."
    opened = Verification.review(term)
    surface = Breeze.Test.start!(Surface, size: {60, 20}, start_opts: opened.assigns)
    on_exit(fn -> Breeze.Test.stop(surface) end)
    assert Breeze.Test.render!(surface) =~ "host work may still be stopping"
  end

  test "actual narrow and wide Breeze setup keeps authorization visible and Enter harmless", %{
    term: term
  } do
    for size <- [{60, 20}, {120, 32}] do
      setup = Verification.open(term)

      surface =
        Breeze.Test.start!(Surface,
          size: size,
          start_opts: setup.assigns,
          global_keybindings: ReyCode.TUI.global_keybindings()
        )

      on_exit(fn -> Breeze.Test.stop(surface) end)
      screen = Breeze.Test.render!(surface)
      assert screen =~ "NOT a sandbox"
      assert screen =~ "Authorize checks and start"
      Breeze.Test.input(surface, "Enter")
      refute_received {:started, _, _}
      Breeze.Test.input(surface, "Tab")
      assert Breeze.Test.metadata(surface).focused == "verify-commands"
      Breeze.Test.input(surface, "t")
      Breeze.Test.input(surface, "r")
      Breeze.Test.input(surface, "u")
      Breeze.Test.input(surface, "e")
      assert Breeze.Test.metadata(surface).assigns.verification.commands == "true"
      Breeze.Test.input(surface, "Tab")
      assert Breeze.Test.metadata(surface).focused == "verify-authorize"
      Breeze.Test.input(surface, "Enter")
      assert_received {:started, "source", %{commands: ["true"]}}
      assert Breeze.Test.metadata(surface).assigns.selected_session_id == "new"
      assert Breeze.Test.render!(surface) =~ "Session new"
    end
  end

  test "actual review pages all retained patch text and navigates files and hunks", %{term: term} do
    for size <- [{60, 20}, {120, 32}] do
      opened = term |> with_change(change()) |> Verification.review()
      surface = Breeze.Test.start!(Surface, size: size, start_opts: opened.assigns)
      on_exit(fn -> Breeze.Test.stop(surface) end)
      assert Breeze.Test.render!(surface) =~ "Selected: none"
      Breeze.Test.input(surface, "Enter")
      assert Breeze.Test.metadata(surface).assigns.verification.decision == nil
      Breeze.Test.input(surface, "3")
      assert Breeze.Test.render!(surface) =~ "diff --git a/one b/one"
      Breeze.Test.input(surface, "PageDown")
      assert Breeze.Test.metadata(surface).assigns.verification.offset > 0
      Breeze.Test.input(surface, "n")
      assert Breeze.Test.render!(surface) =~ "diff --git a/two b/two"
      Breeze.Test.input(surface, "]")
      assert Breeze.Test.render!(surface) =~ "@@ -1 +1 @@"
      assert Breeze.Test.render!(surface) =~ "+last retained line"
      Breeze.Test.input(surface, "4")
      assert Breeze.Test.render!(surface) =~ "BASELINE"
      Breeze.Test.input(surface, "d")
      assert Breeze.Test.render!(surface) =~ "Selected: discard"
    end
  end

  test "composer label follows admission and multiline height is bounded with stable slash geometry" do
    assert State.send_label(%Session{}) == "Send"
    assert State.send_label(%Session{active_turn_id: "turn"}) == "Queue"
    assert State.send_label(%Session{queued_turn_ids: ["turn"]}) == "Queue"
    assert State.composer_height("one\ntwo\nthree", nil, 24) == 5
    assert State.composer_height(String.duplicate("line\n", 100), nil, 24) == 8
    assert State.composer_height("one\ntwo\nthree", :slash, 24) == 2
  end

  defp with_change(term, change),
    do: put_in(term.assigns.projection.sessions["source"].verified_change, change)

  defp change do
    %VerifiedChange{
      id: "change",
      phase: "ready",
      prompt: "Fix parser",
      commands: ["true"],
      source_workspace: "/source",
      workspace: "/isolated",
      base_commit: "base",
      patch_hash: "exact-hash",
      repair_count: 0,
      max_repair_count: 1,
      timeout_ms: 600_000,
      check_timeout_ms: 120_000,
      baseline: [
        %{
          "command" => "true",
          "exit_code" => 1,
          "output" => "old failure",
          "snapshot_hash" => "base",
          "error" => nil
        }
      ],
      checks: [
        %{
          "command" => "true",
          "exit_code" => 0,
          "output" => "passed",
          "snapshot_hash" => "exact-hash",
          "error" => nil
        }
      ],
      patch:
        "diff --git a/one b/one\n@@ -1 +1 @@\n" <>
          Enum.map_join(1..50, "\n", &"+line #{&1}") <>
          "\ndiff --git a/two b/two\n@@ -1 +1 @@\n+last retained line"
    }
  end
end
