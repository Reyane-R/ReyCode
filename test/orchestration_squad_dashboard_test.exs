defmodule ReyCode.Orchestration.Squad.DashboardTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Squad
  alias ReyCode.Orchestration.Squad.Dashboard

  test "shapes the most recent squad turn for a room" do
    older = squad_turn("older", "room-1", "2026-01-01T00:00:00Z")

    newer =
      squad_turn("newer", "room-1", "2026-01-02T00:00:00Z", %{
        decisions: [%{id: 1}, %{id: 2}],
        gate_reviews: [%{id: 3}, %{id: 4}],
        artifacts: [%{id: 5}, %{id: 6}],
        retries: [%{id: 7}, %{id: 8}],
        directives: [%{id: 9}, %{id: 10}]
      })

    projection = %{
      turns: %{"older" => older, "newer" => newer},
      invocations: %{}
    }

    dashboard = Dashboard.data(%{id: "room-1", active_turn_id: nil}, projection)

    assert dashboard.turn == newer
    assert dashboard.phases == Enum.with_index(Squad.phases())
    assert dashboard.decisions == [%{id: 2}, %{id: 1}]
    assert dashboard.reviews == [%{id: 4}, %{id: 3}]
    assert dashboard.artifacts == [%{id: 6}, %{id: 5}]
    assert dashboard.retries == [%{id: 8}, %{id: 7}]
    assert dashboard.directives == [%{id: 10}, %{id: 9}]
    assert dashboard.usage == %{tokens: 0, cost: 0.0, cost_known?: false, invocations: 0}
  end

  test "prefers the active squad turn and defaults optional dashboard lists" do
    active = squad_turn("active", "room-1", "2026-01-01T00:00:00Z")
    newer = squad_turn("newer", "room-1", "2026-01-02T00:00:00Z")
    projection = %{turns: %{"active" => active, "newer" => newer}, invocations: %{}}

    dashboard = Dashboard.data(%{id: "room-1", active_turn_id: "active"}, projection)

    assert dashboard.turn == active
    assert dashboard.reviews == []
    assert dashboard.directives == []
  end

  test "returns nil when the room has no squad turn" do
    regular_turn = %{id: "regular", room_id: "room-1", mode: :compare, squad: nil}
    projection = %{turns: %{"regular" => regular_turn}, invocations: %{}}

    assert Dashboard.data(%{id: "room-1", active_turn_id: "regular"}, projection) == nil
  end

  test "marks completed, current, pending, and terminal current phases" do
    running = squad_turn("running", "room-1", "", %{stage: 1, status: :running})
    completed = put_in(running.status, :completed)

    assert Dashboard.phase_marker(0, running) == "[x]"
    assert Dashboard.phase_class(0, running) == "text-success"
    assert Dashboard.phase_marker(1, running) == "[>]"
    assert Dashboard.phase_class(1, running) == "font-bold text-primary"
    assert Dashboard.phase_marker(2, running) == "[ ]"
    assert Dashboard.phase_class(2, running) == "text-muted"
    assert Dashboard.phase_marker(1, completed) == "[x]"
  end

  test "builds the exact dashboard labels" do
    assert Dashboard.gate_label(%{gate: true}) == "  [gate]"
    assert Dashboard.gate_label(%{}) == ""

    assert Dashboard.decision_label(%{
             phase: "story_gate",
             cycle: 2,
             decision: "rework",
             actor: "owner",
             target_phase: "stories"
           }) == "story_gate / cycle 2 / rework / owner -> stories"

    assert Dashboard.decision_label(%{
             phase: "story_gate",
             cycle: 0,
             decision: "approve",
             target_phase: nil
           }) == "story_gate / cycle 0 / approve / agent"

    assert Dashboard.review_label(%{phase: "release_gate", cycle: 1, decision: "approve"}) ==
             "release_gate / cycle 1 / leader recommends approve"

    assert Dashboard.artifact_label(%{kind: "stories", phase: "story_review", cycle: 0}) ==
             "stories / story_review / cycle 0"

    assert Dashboard.retry_label(%{
             phase: "story_review",
             role_id: "reviewer",
             attempt: 2,
             kind: "provider_retry"
           }) == "story_review / reviewer / attempt 2 / provider_retry"
  end

  test "aggregates all supported token forms and only numeric costs" do
    usages = [
      %{"total_tokens" => 4.9, "cost" => 0.001},
      %{tokens: 3.8},
      %{tokens: %{"total" => 5.2}, cost: "unknown"},
      %{tokens: %{input: 2, output: 3}, cost: 0},
      %{prompt_tokens: 7, completion_tokens: 11},
      %{"input_tokens" => 13, "output_tokens" => 17, "cost" => 0.002}
    ]

    turn = %{invocation_order: Enum.map(1..7, &"inv-#{&1}")}

    invocations =
      usages
      |> Enum.with_index(1)
      |> Map.new(fn {usage, index} -> {"inv-#{index}", %{usage: usage}} end)

    projection = %{invocations: invocations}

    assert Dashboard.summarize_usage(turn, projection) == %{
             tokens: 65,
             cost: 0.003,
             cost_known?: true,
             invocations: 6
           }
  end

  test "formats unavailable, unpriced, and priced usage" do
    assert Dashboard.usage_label(%{invocations: 0}) == "usage unavailable"

    assert Dashboard.usage_label(%{
             tokens: 15,
             invocations: 1,
             cost: 0.0,
             cost_known?: false
           }) == "15 tokens / 1 measured invocations / cost unavailable"

    assert Dashboard.usage_label(%{
             tokens: 15,
             invocations: 1,
             cost: 0.0025,
             cost_known?: true
           }) == "15 tokens / 1 measured invocations / $0.0025"
  end

  defp squad_turn(id, room_id, created_at, overrides \\ %{}) do
    squad = %{
      stage: 0,
      decisions: [],
      artifacts: [],
      retries: []
    }

    %{
      id: id,
      room_id: room_id,
      mode: :squad,
      status: Map.get(overrides, :status, :completed),
      invocation_order: [],
      squad: Map.merge(squad, Map.drop(overrides, [:status])),
      created_at: created_at
    }
  end
end
