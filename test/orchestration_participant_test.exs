defmodule ReyCode.Orchestration.ParticipantTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Participant

  test "from_map keeps atom kinds and normalizes string kinds" do
    assert Participant.from_map(%{id: "p1", kind: :primary}).kind == :primary
    assert Participant.from_map(%{id: "p1", kind: "primary"}).kind == :primary
    assert Participant.from_map(%{id: "p1", kind: :task}).kind == :task
    assert Participant.from_map(%{id: "p1", kind: "task"}).kind == :task
  end

  test "from_map falls back to the legacy kind for unknown values" do
    assert Participant.from_map(%{id: "p1"}).kind == :legacy
    assert Participant.from_map(%{id: "p1", kind: "crew"}).kind == :legacy
    assert Participant.from_map(%{id: "p1", kind: 7}).kind == :legacy
  end

  test "from_map defaults a missing tier from the participant kind" do
    assert Participant.from_map(%{id: "p1", kind: :task}).model_tier == :smol
    assert Participant.from_map(%{id: "p1", kind: :primary}).model_tier == :default
    assert Participant.from_map(%{id: "p1"}).model_tier == :default
  end

  test "from_map falls back to the kind default when the tier is invalid" do
    assert Participant.from_map(%{id: "p1", kind: :task, model_tier: "giant"}).model_tier == :smol

    assert Participant.from_map(%{id: "p1", kind: :primary, model_tier: :giant}).model_tier ==
             :default
  end

  test "from_map normalizes valid string tiers and drops unknown keys" do
    participant =
      Participant.from_map(%{
        id: "p1",
        name: "Builder",
        perspective: "implementation",
        provider: :simulator,
        model: "sim-1",
        model_tier: "slow",
        kind: "task",
        extra: "ignored"
      })

    assert participant == %Participant{
             id: "p1",
             name: "Builder",
             perspective: "implementation",
             provider: :simulator,
             model: "sim-1",
             model_tier: :slow,
             kind: :task
           }
  end
end
