defmodule ReyCode.Orchestration.Squad do
  @moduledoc "Fixed leader-supervised squad roster and workflow definition."

  alias ReyCode.Orchestration.Squad.{Phase, Role}

  @workflow_version "squad-v3"
  @max_rework 3
  @retry_limit 2

  @roles [
           %{
             id: "squad_leader",
             name: "Squad Leader",
             perspective: "supervision, gate decisions, and targeted rework",
             artifacts: ["theme_brief"],
             decisions: ["approve", "rework", "abort"]
           },
           %{
             id: "analyst",
             name: "Analyst",
             perspective: "themes, requirements, and story decomposition",
             artifacts: ["stories"],
             decisions: []
           },
           %{
             id: "reviewer",
             name: "Reviewer",
             perspective: "story gaps, contradictions, and delivery risks",
             artifacts: ["story_review"],
             decisions: []
           },
           %{
             id: "gherkin_author",
             name: "Gherkin Author",
             perspective: "executable behavior and acceptance scenarios",
             artifacts: ["gherkin"],
             decisions: []
           },
           %{
             id: "qa_author",
             name: "QA Author",
             perspective: "unit, integration, and acceptance test design",
             artifacts: ["qa_plan"],
             decisions: []
           },
           %{
             id: "implementer",
             name: "Implementer",
             perspective: "code, unit tests, and acceptance tests",
             artifacts: ["code", "unit_tests", "acceptance_tests"],
             decisions: []
           },
           %{
             id: "cleaner",
             name: "Cleaner",
             perspective: "simple, maintainable, dead-code-free implementation",
             artifacts: ["cleaned_code"],
             decisions: []
           },
           %{
             id: "code_reviewer",
             name: "Code Reviewer",
             perspective: "independent correctness and maintainability review",
             artifacts: ["code_review"],
             decisions: []
           },
           %{
             id: "hardener",
             name: "Hardener",
             perspective: "security, reliability, and failure boundaries",
             artifacts: ["hardened_code"],
             decisions: []
           },
           %{
             id: "qa_tester",
             name: "QA Tester",
             perspective: "executed verification and regression evidence",
             artifacts: ["qa_evidence"],
             decisions: []
           },
           %{
             id: "architect",
             name: "Architect",
             perspective: "final architecture and boundary validation",
             artifacts: ["architecture_review"],
             decisions: []
           },
           %{
             id: "senior_implementer",
             name: "Senior Implementer",
             perspective: "integration and remediation of cross-cutting findings",
             artifacts: ["integrated_implementation"],
             decisions: []
           }
         ]
         |> Enum.map(&Role.from_map/1)

  @phases [
            %{id: "leader_intake", roles: ["squad_leader"], artifacts: ["theme_brief"]},
            %{id: "stories", roles: ["analyst"], artifacts: ["stories"]},
            %{id: "story_review", roles: ["reviewer"], artifacts: ["story_review"]},
            %{id: "story_gate", roles: ["squad_leader"], gate: true, rework_to: "stories"},
            %{
              id: "specification",
              roles: ["gherkin_author", "qa_author"],
              artifacts: ["gherkin", "qa_plan"]
            },
            %{
              id: "specification_gate",
              roles: ["squad_leader"],
              gate: true,
              rework_to: "specification"
            },
            %{
              id: "implementation",
              roles: ["implementer"],
              artifacts: ["code", "unit_tests", "acceptance_tests"]
            },
            %{
              id: "integration",
              roles: ["senior_implementer"],
              artifacts: ["integrated_implementation"]
            },
            %{id: "cleanup", roles: ["cleaner"], artifacts: ["cleaned_code"]},
            %{id: "code_review", roles: ["code_reviewer"], artifacts: ["code_review"]},
            %{id: "code_gate", roles: ["squad_leader"], gate: true, rework_to: "integration"},
            %{id: "hardening", roles: ["hardener"], artifacts: ["hardened_code"]},
            %{id: "qa_validation", roles: ["qa_tester"], artifacts: ["qa_evidence"]},
            %{
              id: "architecture_review",
              roles: ["architect"],
              artifacts: ["architecture_review"]
            },
            %{id: "release_gate", roles: ["squad_leader"], gate: true, rework_to: "integration"}
          ]
          |> Enum.map(&Phase.from_map/1)

  @role_by_id Map.new(@roles, &{&1.id, &1})
  @phase_by_id Map.new(@phases, &{&1.id, &1})
  @phase_index @phases |> Enum.with_index() |> Map.new(fn {phase, index} -> {phase.id, index} end)

  @type role :: Role.t()
  @type phase :: Phase.t()

  @doc "Returns the workflow version persisted with squad runs."
  @spec workflow_version() :: String.t()
  def workflow_version, do: @workflow_version

  @doc "Returns the canonical squad roster in workflow order."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "Looks up a squad role by its stable ID."
  @spec role(String.t()) :: role() | nil
  def role(role_id), do: @role_by_id[role_id]

  @doc "Returns the ordered squad workflow phases."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "Looks up a workflow phase by index or stable ID."
  def phase(nil), do: nil
  def phase(index) when is_integer(index), do: Enum.at(@phases, index)
  def phase(id) when is_binary(id), do: @phase_by_id[id]

  @doc "Returns the numeric stage index for a phase ID."
  @spec phase_index(String.t()) :: non_neg_integer() | nil
  def phase_index(id), do: @phase_index[id]

  @doc "Returns a stable Phase label, or `\"complete\"` after the final Phase."
  @spec phase_label(non_neg_integer()) :: String.t()
  def phase_label(index) do
    case phase(index) do
      nil -> "complete"
      value -> value.id
    end
  end

  @doc "Returns the Roles responsible for a workflow Phase."
  @spec roles_in_phase(non_neg_integer()) :: [Role.t()]
  def roles_in_phase(index) do
    case phase(index) do
      nil -> []
      value -> Enum.map(value.role_ids, &Map.fetch!(@role_by_id, &1))
    end
  end

  @doc "Checks whether a Phase requires a gate resolution."
  @spec gate?(non_neg_integer() | Phase.t()) :: boolean()
  def gate?(index) when is_integer(index), do: gate?(phase(index))
  def gate?(nil), do: false
  def gate?(phase), do: phase.gate?

  @doc "Returns the default number of rework cycles allowed per squad run."
  @spec max_rework() :: pos_integer()
  def max_rework, do: @max_rework

  @doc "Returns the maximum provider attempts allowed for squad work."
  @spec retry_limit() :: pos_integer()
  def retry_limit, do: @retry_limit

  @doc "Returns the sentinel PhaseIndex representing workflow completion."
  @spec complete_phase_index() :: pos_integer()
  def complete_phase_index, do: length(@phases)

  @doc "Checks whether a role may perform an action for the given artifact or decision."
  @spec eligible?(String.t(), atom(), atom() | String.t()) :: boolean()
  def eligible?("implementer", :record_legacy, "implementation"), do: true
  def eligible?(_role_id, :record_legacy, _value), do: false

  def eligible?(role_id, action, value) do
    value = to_string(value)

    case role(role_id) do
      nil -> false
      _role when action == :speak -> true
      role when action == :record -> value in role.artifacts
      role when action == :decide -> value in role.decisions
      _role -> false
    end
  end

  @doc "Returns the artifacts a role is responsible for in a phase."
  @spec required_artifacts(String.t(), String.t()) :: [String.t()]
  def required_artifacts(phase_id, role_id) do
    with %Phase{artifact_kinds: artifact_kinds} <- phase(phase_id),
         %Role{artifacts: role_artifacts} <- role(role_id) do
      Enum.filter(artifact_kinds, &(&1 in role_artifacts))
    else
      _ -> []
    end
  end

  @doc """
  Returns every artifact kind a role may legitimately record in a phase.

  This is the phase-aware acceptance set for provider output: the required
  kinds for the phase plus the legacy envelopes that phase still completes
  with. A kind the role owns in some *other* phase is not acceptable here.
  """
  @spec acceptable_artifacts(String.t() | nil, String.t()) :: [String.t()]
  def acceptable_artifacts(phase_id, role_id) do
    Enum.uniq(required_artifacts(phase_id, role_id) ++ legacy_artifacts(role_id))
  end

  @doc "Checks whether a role is the decider for a phase's gate."
  @spec decides_gate?(String.t() | nil, String.t()) :: boolean()
  def decides_gate?(phase_id, role_id) do
    case phase(phase_id) do
      %Phase{gate?: true, role_ids: role_ids} -> role_id in role_ids
      _other -> false
    end
  end

  # Schema-v2 logs may carry the former single implementation envelope; it is
  # acceptable only from the role whose phase still completes with it.
  @legacy_artifacts ["implementation"]

  defp legacy_artifacts(role_id),
    do: Enum.filter(@legacy_artifacts, &eligible?(role_id, :record_legacy, &1))

  @doc "Checks whether the recorded artifact kinds satisfy a phase's requirements."
  @spec phase_artifacts_complete?(phase(), MapSet.t(String.t())) :: boolean()
  def phase_artifacts_complete?(phase, artifact_kinds) do
    Enum.all?(phase.artifact_kinds, &MapSet.member?(artifact_kinds, &1)) or
      legacy_phase_artifacts_complete?(phase.id, artifact_kinds)
  end

  # Schema-v2 logs may contain the former single implementation envelope.
  defp legacy_phase_artifacts_complete?("implementation", artifact_kinds),
    do: MapSet.member?(artifact_kinds, "implementation")

  defp legacy_phase_artifacts_complete?(_phase, _artifact_kinds), do: false

  @doc "Returns the role allowed to cover a failed role, if any."
  @spec fallback(String.t()) :: String.t() | nil
  def fallback(role_id)
      when role_id in ~w(implementer cleaner code_reviewer hardener qa_tester architect),
      do: "senior_implementer"

  def fallback(_role_id), do: nil
end
