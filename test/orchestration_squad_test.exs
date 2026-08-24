defmodule ReyCode.Orchestration.SquadTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Squad

  test "defines the leader and eleven fixed worker seats" do
    assert Enum.map(Squad.roles(), & &1.id) == ~w(
             squad_leader analyst reviewer gherkin_author qa_author implementer cleaner
             code_reviewer hardener qa_tester architect senior_implementer
           )
  end

  test "encodes the fixed themes-to-architecture workflow" do
    assert Enum.map(Squad.phases(), & &1.id) == ~w(
             leader_intake stories story_review story_gate specification specification_gate
             implementation integration cleanup code_review code_gate hardening qa_validation
             architecture_review release_gate
           )

    assert Enum.map(Squad.roles_in_phase(4), & &1.id) == ["gherkin_author", "qa_author"]
  end

  test "only the squad leader may decide gates" do
    assert Squad.eligible?("squad_leader", :decide, "approve")
    assert Squad.eligible?("squad_leader", :decide, :rework)
    assert Squad.eligible?("squad_leader", :decide, "abort")

    refute Squad.eligible?("reviewer", :decide, "rework")
    refute Squad.eligible?("architect", :decide, "approve")
  end

  test "workers may only record their declared artifacts" do
    assert Squad.eligible?("analyst", :record, "stories")
    assert Squad.eligible?("gherkin_author", :record, :gherkin)
    assert Squad.eligible?("qa_tester", :record, "qa_evidence")
    assert Squad.eligible?("implementer", :record, "code")
    assert Squad.eligible?("implementer", :record, "unit_tests")
    assert Squad.eligible?("implementer", :record, "acceptance_tests")
    refute Squad.eligible?("implementer", :record, "implementation")

    refute Squad.eligible?("analyst", :record, "code_review")
  end

  test "senior implementer owns integration and downstream fallback" do
    assert Squad.phase("integration").role_ids == ["senior_implementer"]
    assert Squad.fallback("implementer") == "senior_implementer"
    assert Squad.fallback("hardener") == "senior_implementer"
    assert Squad.fallback("analyst") == nil
  end

  test "leader gates have bounded targeted rework" do
    assert Squad.max_rework() == 3
    assert Squad.phase("story_gate").rework_phase == "stories"
    assert Squad.phase("specification_gate").rework_phase == "specification"
    assert Squad.phase("code_gate").rework_phase == "integration"
    assert Squad.phase("release_gate").rework_phase == "integration"
  end

  test "phase completion accepts current artifact bundles" do
    phase = Squad.phase("implementation")
    artifacts = MapSet.new(~w(code unit_tests acceptance_tests))

    assert Squad.phase_artifacts_complete?(phase, artifacts)
    refute Squad.phase_artifacts_complete?(phase, MapSet.delete(artifacts, "unit_tests"))
  end

  test "phase completion remains compatible with legacy implementation envelopes" do
    assert Squad.phase_artifacts_complete?(
             Squad.phase("implementation"),
             MapSet.new(["implementation"])
           )
  end
end
