defmodule ReyCode.Provider.ContextBudgetTest do
  use ExUnit.Case, async: true

  alias ReyCode.{Failure, Provider}
  alias ReyCode.Provider.{ContextBudget, Request, Runtime}

  defmodule CrashingProvider do
    @behaviour ReyCode.Provider

    @impl true
    def stream(_runtime, _request, _emit), do: raise("unused")

    @impl true
    def context_budget(_runtime, _request), do: raise("preflight crashed")
  end

  defmodule InvalidProvider do
    @behaviour ReyCode.Provider

    @impl true
    def stream(_runtime, _request, _emit), do: raise("unused")

    @impl true
    def context_budget(_runtime, _request), do: :invalid
  end

  test "the exact byte ceiling is hard while the maintenance threshold is advisory" do
    assert %ContextBudget{
             status: :ready,
             maintenance_prompt_bytes: 800,
             target_prompt_bytes: 600,
             maintenance_input_tokens: 8_000,
             target_input_tokens: 6_000
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

  test "provider preflight contains adapter exceptions and malformed replies" do
    request = %Request{
      invocation_id: "inv-1",
      turn_id: "turn-1",
      session_id: "session-1",
      mode: :direct,
      participant: %{},
      system_prompt: "",
      messages: [],
      workspace: System.tmp_dir!(),
      resume_from: 0,
      round_index: 0
    }

    crashing_runtime = %Runtime{module: CrashingProvider, status: :available}

    assert {:error, %Failure{category: :internal, message: "preflight crashed"}} =
             Provider.context_budget(crashing_runtime, request)

    invalid_runtime = %Runtime{module: InvalidProvider, status: :available}

    assert {:error, %Failure{category: :invalid_output}} =
             Provider.context_budget(invalid_runtime, request)
  end
end
