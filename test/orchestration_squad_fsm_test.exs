defmodule ReyCode.Orchestration.SquadFSMTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Squad, SquadFSM}

  test "starts at leader intake" do
    state = SquadFSM.new("room-1")

    assert state.phase == 0
    assert state.cycle == 0
    assert SquadFSM.stage_label(state) == "leader_intake"
    refute SquadFSM.complete?(state)
  end

  test "walks non-gate phases in fixed order" do
    state = SquadFSM.new("room-1")
    assert {:continue, state} = SquadFSM.next(state)
    assert SquadFSM.stage_label(state) == "stories"
    assert {:continue, state} = SquadFSM.next(state)
    assert SquadFSM.stage_label(state) == "story_review"
    assert {:continue, state} = SquadFSM.next(state)
    assert SquadFSM.stage_label(state) == "story_gate"
  end

  test "worker gate outputs cannot advance a gate" do
    state = advance_to(SquadFSM.new("room-1"), Squad.phase_index("story_gate"))

    assert {:error, :leader_required} =
             SquadFSM.gate(state, %{
               "role_id" => "reviewer",
               "decision" => "approve",
               "target_phase" => nil
             })

    assert {:continue, next} =
             SquadFSM.gate(state, %{
               "role_id" => "squad_leader",
               "decision" => "approve",
               "target_phase" => nil
             })

    assert SquadFSM.stage_label(next) == "specification"
  end

  test "leader rework is targeted and bounded" do
    state = advance_to(SquadFSM.new("room-1", rework_budget: 1), Squad.phase_index("code_gate"))

    gate = %{
      "role_id" => "squad_leader",
      "decision" => "rework",
      "target_phase" => "integration"
    }

    assert {:continue, state} = SquadFSM.gate(state, gate)
    assert SquadFSM.stage_label(state) == "integration"
    assert state.cycle == 1
    assert state.rework_count == 1

    state = advance_to(state, Squad.phase_index("code_gate"))
    assert {:complete, state} = SquadFSM.gate(state, gate)
    assert state.outcome == :failed
  end

  test "release approval completes the workflow" do
    state = advance_to(SquadFSM.new("room-1"), Squad.phase_index("release_gate"))

    assert {:complete, state} =
             SquadFSM.gate(state, %{
               "role_id" => "squad_leader",
               "decision" => "approve",
               "target_phase" => nil
             })

    assert SquadFSM.complete?(state)
    assert SquadFSM.outcome(state) == :completed
  end

  test "the human owner may authoritatively resolve the release gate" do
    state = advance_to(SquadFSM.new("room-1"), Squad.phase_index("release_gate"))

    assert {:complete, state} =
             SquadFSM.gate(state, %{
               "role_id" => "human_owner",
               "decision" => "approve",
               "target_phase" => nil
             })

    assert SquadFSM.outcome(state) == :completed
  end

  test "leader may abort" do
    state = advance_to(SquadFSM.new("room-1"), Squad.phase_index("story_gate"))

    assert {:complete, state} =
             SquadFSM.gate(state, %{
               "role_id" => "squad_leader",
               "decision" => "abort",
               "target_phase" => nil
             })

    assert SquadFSM.outcome(state) == :failed
  end

  test "the human owner may grant rework beyond an exhausted budget" do
    state =
      "room-1"
      |> SquadFSM.new(rework_budget: 1)
      |> advance_to(Squad.phase_index("code_gate"))
      |> Map.put(:rework_count, 1)

    assert {:continue, granted} =
             SquadFSM.gate(state, %{
               "role_id" => "human_owner",
               "decision" => "rework",
               "target_phase" => "integration"
             })

    assert granted.rework_budget == 2
    assert granted.rework_count == 2
    assert granted.cycle == 1

    assert {:complete, failed} =
             SquadFSM.gate(state, %{
               "role_id" => "squad_leader",
               "decision" => "rework",
               "target_phase" => "integration"
             })

    assert SquadFSM.outcome(failed) == :failed
  end

  defp advance_to(state, target) when state.phase >= target, do: state

  defp advance_to(state, target) do
    {:continue, state} = SquadFSM.next(state)
    advance_to(state, target)
  end
end
