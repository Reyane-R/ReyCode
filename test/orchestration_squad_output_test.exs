defmodule ReyCode.Orchestration.Squad.OutputTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  test "rejects artifact bundles with non-map elements instead of raising" do
    invocation =
      invocation(
        "implementer",
        %{
          "squad_output" => %{
            "kind" => "artifacts",
            "artifacts" => [
              %{"artifact_type" => "code", "summary" => "Code", "blockers" => []},
              42,
              %{"artifact_type" => "unit_tests", "summary" => "Tests", "blockers" => []},
              %{
                "artifact_type" => "acceptance_tests",
                "summary" => "Acceptance",
                "blockers" => []
              }
            ]
          }
        },
        "implementation"
      )

    assert {:error, :invalid_artifact_bundle} = Output.parse(invocation, %{body: ""})
  end

  test "rejects artifact bundles with duplicate artifact kinds" do
    invocation =
      invocation(
        "implementer",
        %{
          "squad_output" => %{
            "kind" => "artifacts",
            "artifacts" => [
              %{"artifact_type" => "code", "summary" => "Code 1", "blockers" => []},
              %{"artifact_type" => "unit_tests", "summary" => "Tests", "blockers" => []},
              %{
                "artifact_type" => "acceptance_tests",
                "summary" => "Acceptance",
                "blockers" => []
              },
              %{"artifact_type" => "code", "summary" => "Code 2", "blockers" => []}
            ]
          }
        },
        "implementation"
      )

    assert {:error, :invalid_artifact_bundle} = Output.parse(invocation, %{body: ""})
  end

  test "rejects artifact bundles with unexpected artifact kinds" do
    invocation =
      invocation(
        "implementer",
        %{
          "squad_output" => %{
            "kind" => "artifacts",
            "artifacts" => [
              %{"artifact_type" => "code", "summary" => "Code", "blockers" => []},
              %{"artifact_type" => "unit_tests", "summary" => "Tests", "blockers" => []},
              %{
                "artifact_type" => "acceptance_tests",
                "summary" => "Acceptance",
                "blockers" => []
              },
              %{"artifact_type" => "stories", "summary" => "Sneaky", "blockers" => []}
            ]
          }
        },
        "implementation"
      )

    assert {:error, :invalid_artifact_bundle} = Output.parse(invocation, %{body: ""})
  end

  test "rejects artifact bundles whose artifacts value is not a list" do
    invocation =
      invocation(
        "implementer",
        %{
          "squad_output" => %{
            "kind" => "artifacts",
            "artifacts" => "not a list"
          }
        },
        "implementation"
      )

    assert {:error, :invalid_artifact_bundle} = Output.parse(invocation, %{body: ""})
  end

  test "rejects artifacts with non-string blockers" do
    invocation =
      invocation("analyst", %{
        "squad_output" => %{
          "kind" => "artifact",
          "artifact_type" => "stories",
          "summary" => "Stories ready",
          "blockers" => [%{"nested" => true}]
        }
      })

    assert {:error, :invalid_artifact} = Output.parse(invocation, %{body: ""})
  end

  test "rejects gate decisions with non-string reasons" do
    invocation =
      invocation("squad_leader", %{
        "squad_output" => %{
          "kind" => "gate",
          "decision" => "approve",
          "reasons" => [%{"nested" => true}, 42]
        }
      })

    assert {:error, :invalid_gate} = Output.parse(invocation, %{body: ""})
  end

  test "rejects gate decisions with non-binary decisions instead of raising" do
    invocation =
      invocation("squad_leader", %{
        "squad_output" => %{
          "kind" => "gate",
          "decision" => %{"not" => "a decision"},
          "reasons" => []
        }
      })

    assert {:error, :invalid_gate} = Output.parse(invocation, %{body: ""})
  end

  property "never raises for any JSON-decodable metadata or message body" do
    check all(
            metadata <- json_term(),
            body_term <- json_term(),
            body_is_json? <- StreamData.boolean()
          ) do
      invocation = invocation("analyst", metadata, "stories")
      body = if body_is_json?, do: Jason.encode!(body_term), else: body_term

      result = Output.parse(invocation, %{body: body})
      assert match?({:ok, _output}, result) or match?({:error, _reason}, result)
    end
  end

  defp invocation(role_id, metadata, phase \\ nil) do
    %{participant: %{id: role_id}, completion_metadata: metadata, phase: phase}
  end

  defp json_term do
    StreamData.sized(fn size -> json_term(min(size, 5)) end)
  end

  defp json_term(0) do
    StreamData.one_of([
      StreamData.member_of([nil, true, false]),
      StreamData.integer(),
      StreamData.string(:printable)
    ])
  end

  defp json_term(depth) do
    StreamData.one_of([
      StreamData.member_of([nil, true, false]),
      StreamData.integer(),
      StreamData.float(),
      StreamData.string(:printable),
      StreamData.list_of(json_term(depth - 1), max_length: 3),
      StreamData.map_of(StreamData.string(:printable), json_term(depth - 1), max_length: 3)
    ])
  end
end
