defmodule ReyCode.Orchestration.InvocationExecutionTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.InvocationExecution

  test "from_map returns nil contexts as defaults" do
    assert InvocationExecution.from_map(nil) == %InvocationExecution{}
  end

  test "from_map returns typed contexts unchanged" do
    context = %InvocationExecution{
      workspace: "/tmp/workspace",
      isolation: %{"workspace" => "/tmp/worktree"},
      merge_decision: :apply,
      model_tier: :smol
    }

    assert InvocationExecution.from_map(context) == context
  end

  test "from_map builds the typed record from a decoded map and drops unknown keys" do
    context =
      InvocationExecution.from_map(%{
        workspace: "/tmp/workspace",
        workspace_roots: ["src"],
        output_schema: %{"type" => "object"},
        isolation: nil,
        merge_decision: "discard",
        model_tier: "slow",
        token_budget_tokens: 32_000,
        extra: "ignored"
      })

    assert context == %InvocationExecution{
             workspace: "/tmp/workspace",
             workspace_roots: ["src"],
             output_schema: %{"type" => "object"},
             isolation: nil,
             merge_decision: "discard",
             model_tier: "slow",
             token_budget_tokens: 32_000
           }
  end
end
