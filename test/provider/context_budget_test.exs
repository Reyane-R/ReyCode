defmodule ReyCode.Provider.ContextBudgetTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.ContextBudget

  test "the exact byte ceiling is hard while the maintenance threshold is advisory" do
    assert %ContextBudget{
             status: :ready,
             maintenance_prompt_bytes: 800,
             target_prompt_bytes: 600
           } = ContextBudget.assess(799, 1_000, 10_000, nil, 1_000)

    assert %ContextBudget{status: :maintenance_required} =
             ContextBudget.assess(800, 1_000, 10_000, nil, 1_000)

    assert %ContextBudget{status: :too_large} =
             ContextBudget.assess(1_001, 1_000, 10_000, nil, 1_000)
  end

  test "model capacity reserves output and operator policy can impose the tighter token budget" do
    model_limited = ContextBudget.assess(8_000, 100_000, 10_000, 3_000, 500)

    assert model_limited.input_budget_tokens == 2_500
    assert model_limited.estimated_prompt_tokens == 2_000
    assert model_limited.status == :maintenance_required
    assert model_limited.model_context_percent == 66

    operator_limited = ContextBudget.assess(8_000, 100_000, 1_500, 3_000, 500)
    assert operator_limited.input_budget_tokens == 1_500
    assert operator_limited.status == :maintenance_required
  end

  test "unknown model capacity does not fabricate a context percentage" do
    assessment = ContextBudget.assess(4_000, 100_000, 2_000, nil, 1_000)

    assert assessment.estimated_prompt_tokens == 1_000
    assert assessment.model_context_percent == nil
  end
end
