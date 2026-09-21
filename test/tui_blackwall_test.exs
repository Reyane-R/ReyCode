defmodule ReyCode.TUI.BlackwallTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Message, Projection, Session}
  alias ReyCode.TUI.{Activity, AnimationClock, Blackwall, State}

  test "a breach while blocked keeps its deadline clock and reduced motion skips it" do
    projection = %Projection{
      sessions: %{"session" => %Session{id: "session", participants: [], message_order: ["new"]}},
      messages: %{"new" => %Message{id: "new", role: :user}}
    }

    for reduced? <- [false, true] do
      clock =
        AnimationClock.new(
          reduced_motion?: reduced?,
          schedule: fn _token, _ms -> make_ref() end,
          cancel: fn _ref -> :ok end
        )

      term = %Breeze.Term{
        assigns: %{
          selected_session_id: "session",
          projection: projection,
          providers: %{},
          home: false,
          animation_clock: clock,
          decoration_now: fn -> 0 end,
          blackwall: %Blackwall{session_id: "session", phase: :blocked}
        }
      }

      started = State.reconcile_animation(term, 0)
      assert AnimationClock.armed?(started.assigns.animation_clock) == not reduced?

      if reduced? do
        assert started.assigns.blackwall.phase == :blocked
      else
        assert started.assigns.blackwall.phase == :breach
        expired = Breeze.Component.assign(started, decoration_now: fn -> 600 end)

        assert {:ok, finished} =
                 State.animation_tick(expired, expired.assigns.animation_clock.token, 0)

        assert finished.assigns.blackwall.phase == :blocked
        refute AnimationClock.armed?(finished.assigns.animation_clock)
      end
    end
  end

  test "new work breaches once, redraws preserve its deadline, and response text calms it" do
    idle = Blackwall.reconcile(%Blackwall{}, assigns(nil), activity(:idle), 0)
    running = assigns("turn-1")
    breach = Blackwall.reconcile(idle, running, activity(:active), 10)
    assert breach.phase == :breach
    assert Blackwall.reconcile(breach, running, activity(:active), 609) == breach
    waiting = Blackwall.reconcile(breach, running, activity(:active), 610)
    assert waiting.phase == :waiting
    assert Blackwall.reconcile(waiting, running, activity(:active), 900) == waiting
    receiving = Blackwall.reconcile(waiting, assigns("turn-1", "hello"), activity(:active), 910)
    assert receiving.phase == :receiving
    assert Blackwall.color(receiving) == "primary"
  end

  test "completion settles for 400 ms and never restarts from historical terminal state" do
    running = Blackwall.reconcile(%Blackwall{}, assigns("turn-1"), activity(:active), 0)
    terminal = activity(:terminal, :completed)
    closing = Blackwall.reconcile(running, assigns(nil), terminal, 100)
    assert Blackwall.settling?(closing)
    assert Blackwall.reconcile(closing, assigns(nil), terminal, 499) == closing
    idle = Blackwall.reconcile(closing, assigns(nil), terminal, 500)
    assert idle.phase == :idle
    refute Blackwall.animated?(idle)
    assert Blackwall.reconcile(idle, assigns(nil), terminal, 900) == idle
    assert Blackwall.reconcile(%Blackwall{}, assigns(nil), terminal, 0).phase == :idle
    assert Blackwall.reconcile(idle, assigns("turn-2"), activity(:active), 1_000).phase == :breach
  end

  test "session switches and returning home never replay a breach or closing sweep" do
    running = Blackwall.reconcile(%Blackwall{}, assigns("turn-1"), activity(:active), 0)
    other = %{assigns("turn-1") | selected_session_id: "other"}
    switched = Blackwall.reconcile(running, other, activity(:active), 100)
    assert switched.phase == :waiting
    home = Blackwall.reconcile(running, %{assigns("turn-1") | home: true}, activity(:active), 100)
    assert home.phase == :idle
    refute Blackwall.animated?(home)
  end

  test "failure, cancellation and approval do not play a success sweep" do
    running = Blackwall.reconcile(%Blackwall{}, assigns("turn-1"), activity(:active), 0)

    for {outcome, phase, color} <- [
          {:failed, :failed, "error"},
          {:cancelled, :cancelled, "boundary"}
        ] do
      wall = Blackwall.reconcile(running, assigns(nil), activity(:terminal, outcome), 100)
      assert wall.phase == phase
      assert Blackwall.color(wall) == color
      refute Blackwall.animated?(wall)
    end

    blocked = Blackwall.reconcile(running, assigns("turn-1"), activity(:blocked), 100)
    assert blocked.phase == :blocked
    assert Blackwall.color(blocked) == "warning"
    refute Blackwall.animated?(blocked)

    assert Blackwall.reconcile(blocked, assigns("turn-1"), activity(:active), 200).phase ==
             :waiting
  end

  test "tool execution takes precedence over existing response text" do
    view = activity(:active)
    tool = %{view | header: %{view.header | kind: :tool}}
    assert Blackwall.reconcile(%Blackwall{}, assigns("turn-1", "text"), tool, 0).phase == :working
  end

  test "delegation stays active and resuming the same Turn does not breach again" do
    running = Blackwall.reconcile(%Blackwall{}, assigns("turn-1"), activity(:active), 0)
    view = activity(:active)
    delegation = %{view | header: %{view.header | kind: :delegation}}
    working = Blackwall.reconcile(running, assigns("turn-1"), delegation, 100)
    assert working.phase == :working
    resumed = Blackwall.reconcile(working, assigns("turn-1"), view, 1_000)
    assert resumed.phase == :waiting
  end

  test "a queued message breaches on acceptance, not when it later starts" do
    running = Blackwall.reconcile(%Blackwall{}, assigns("turn-1"), activity(:active), 0)
    queued = assigns("turn-1", "", "turn-2")
    breach = Blackwall.reconcile(running, queued, activity(:active), 100)
    assert breach.phase == :breach
    waiting = Blackwall.reconcile(breach, queued, activity(:active), 700)
    next = Blackwall.reconcile(waiting, assigns("turn-2"), activity(:active), 800)
    assert next.phase == :waiting
  end

  defp assigns(turn_id, body \\ "", accepted_turn_id \\ :current) do
    accepted_turn_id = if accepted_turn_id == :current, do: turn_id, else: accepted_turn_id
    user_id = if accepted_turn_id, do: "user-#{accepted_turn_id}"
    message_order = if user_id, do: ["message", user_id], else: []

    %{
      selected_session_id: "session",
      home: false,
      projection: %{
        sessions: %{
          "session" => %{active_turn_id: turn_id, message_order: message_order},
          "other" => %{active_turn_id: turn_id, message_order: message_order}
        },
        invocations: %{"invocation" => %{message_id: "message"}},
        messages: %{"message" => %{body: body}, user_id => %{role: :user}}
      }
    }
  end

  defp activity(state, outcome \\ nil) do
    %Activity.View{
      header: %Activity.Item{
        id: "invocation",
        kind: :invocation,
        state: state,
        label: "Thinking",
        active?: state == :active,
        priority: 60,
        outcome: outcome
      }
    }
  end
end
