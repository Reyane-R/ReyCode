defmodule ReyCode.TUI.AnimationClockTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{AnimationClock, Spinner}

  test "active transition schedules exactly one timer and repeated reconcile is idempotent" do
    clock = clock(self())
    clock = AnimationClock.reconcile(clock, true)

    assert_receive {:scheduled, token, 120, timer_ref}
    assert clock.token == token
    assert clock.timer_ref == timer_ref
    assert AnimationClock.armed?(clock)

    assert AnimationClock.reconcile(clock, true) == clock
    refute_receive {:scheduled, _token, _delay, _timer_ref}
  end

  test "valid ticks advance and rearm once while stale tokens are ignored" do
    clock = clock(self()) |> AnimationClock.reconcile(true)
    assert_receive {:scheduled, token, 120, _timer_ref}

    assert :stale = AnimationClock.tick(clock, make_ref(), true)
    refute_receive {:scheduled, _token, _delay, _timer_ref}

    assert {:ok, next} = AnimationClock.tick(clock, token, true)
    assert AnimationClock.frame_index(next) == 1
    assert_receive {:scheduled, next_token, 120, _timer_ref}
    refute next_token == token
  end

  test "active to blocked or terminal cancels once and stale delivery cannot resurrect" do
    clock = clock(self()) |> AnimationClock.reconcile(true)
    assert_receive {:scheduled, token, 120, timer_ref}

    stopped = AnimationClock.reconcile(clock, false)
    refute AnimationClock.armed?(stopped)
    assert_receive {:cancelled, ^timer_ref}
    assert :stale = AnimationClock.tick(stopped, token, true)
    refute_receive {:scheduled, _token, _delay, _timer_ref}
  end

  test "a valid final tick stops without rearming when work is no longer active" do
    clock = clock(self()) |> AnimationClock.reconcile(true)
    assert_receive {:scheduled, token, 120, _timer_ref}

    assert {:ok, stopped} = AnimationClock.tick(clock, token, false)
    refute AnimationClock.armed?(stopped)
    refute_receive {:scheduled, _token, _delay, _timer_ref}
  end

  test "reduced motion keeps a static frame and uses one-second cadence" do
    clock = clock(self(), reduced_motion?: true) |> AnimationClock.reconcile(true)
    assert_receive {:scheduled, token, 1_000, _timer_ref}
    assert AnimationClock.frame_ms(clock) == 1_000

    assert {:ok, next} = AnimationClock.tick(clock, token, true)
    assert AnimationClock.frame_index(next) == 0
    assert_receive {:scheduled, _next_token, 1_000, _timer_ref}
  end

  test "theme frame adapter uses ASCII for dumb terminals" do
    assert Spinner.style("dumb") == :ascii
    assert Spinner.glyph(0, false, :ascii) == "|"
    assert Spinner.glyph(1, false, :ascii) == "/"
    assert Spinner.glyph(8, true, :ascii) == "*"
  end

  defp clock(test_pid, opts \\ []) do
    schedule = fn token, delay_ms ->
      timer_ref = make_ref()
      send(test_pid, {:scheduled, token, delay_ms, timer_ref})
      timer_ref
    end

    cancel = fn timer_ref ->
      send(test_pid, {:cancelled, timer_ref})
      true
    end

    AnimationClock.new([schedule: schedule, cancel: cancel] ++ opts)
  end
end
