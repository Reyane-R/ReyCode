defmodule ReyCode.Orchestration.Squad.OutputTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Squad.Output

  test "accepts an authorized worker artifact" do
    invocation =
      invocation("analyst", %{
        "squad_output" => %{
          "kind" => "artifact",
          "artifact_type" => "stories",
          "summary" => "Stories ready",
          "blockers" => []
        }
      })

    assert {:ok, %{"role_id" => "analyst"}} = Output.parse(invocation, %{body: ""})
  end

  test "rejects worker gate decisions" do
    invocation =
      invocation("reviewer", %{
        "squad_output" => %{
          "kind" => "gate",
          "decision" => "rework",
          "target_phase" => "stories",
          "reasons" => []
        }
      })

    assert {:error, :invalid_gate} = Output.parse(invocation, %{body: ""})
  end

  test "requires separate code, unit test, and acceptance test artifacts" do
    invocation =
      invocation(
        "implementer",
        %{
          "squad_output" => %{
            "kind" => "artifacts",
            "artifacts" => [
              %{"artifact_type" => "code", "summary" => "Code ready", "blockers" => []},
              %{
                "artifact_type" => "unit_tests",
                "summary" => "Unit tests ready",
                "blockers" => []
              },
              %{
                "artifact_type" => "acceptance_tests",
                "summary" => "Acceptance tests ready",
                "blockers" => []
              }
            ]
          }
        },
        "implementation"
      )

    assert {:ok, %{"kind" => "artifacts", "artifacts" => artifacts}} =
             Output.parse(invocation, %{body: ""})

    assert MapSet.new(artifacts, & &1["artifact_type"]) ==
             MapSet.new(~w(code unit_tests acceptance_tests))
  end

  test "rejects incomplete implementation artifact bundles" do
    invocation =
      invocation(
        "implementer",
        %{
          "squad_output" => %{
            "kind" => "artifacts",
            "artifacts" => [
              %{"artifact_type" => "code", "summary" => "Code only", "blockers" => []}
            ]
          }
        },
        "implementation"
      )

    assert {:error, :invalid_artifact_bundle} = Output.parse(invocation, %{body: ""})
  end

  test "parses a strict JSON leader gate from provider text" do
    invocation = invocation("squad_leader", %{})
    body = Jason.encode!(%{"kind" => "gate", "decision" => "approve", "reasons" => []})

    assert {:ok, %{"decision" => "approve", "target_phase" => nil}} =
             Output.parse(invocation, %{body: body})
  end

  defp invocation(role_id, metadata, phase \\ nil) do
    %{participant: %{id: role_id}, completion_metadata: metadata, phase: phase}
  end
end
