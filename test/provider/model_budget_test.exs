defmodule ReyCode.Provider.ModelBudgetTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.ModelBudget

  @fallback %ModelBudget{
    max_prompt_bytes: 128_000,
    context_window_tokens: nil,
    output_reserve_tokens: 16_384
  }

  test "uses the provider fallback when no exact entry exists" do
    assert ModelBudget.resolve(:zai, "GLM-4.7", @fallback, %{}) == @fallback
    assert ModelBudget.resolve(:zai, "glm-4.7-preview", @fallback, %{}) == @fallback
    assert ModelBudget.resolve(:other, "glm-4.7", @fallback, %{}) == @fallback
  end

  test "applies trusted GLM-4.7 metadata only to its exact Z.ai provider/model pairs" do
    for provider_id <- [:zai, :zai_coding] do
      budget = ModelBudget.resolve(provider_id, "glm-4.7", @fallback, %{})

      assert budget.max_prompt_bytes == 2_000_000
      assert budget.context_window_tokens == 200_000
      assert budget.output_reserve_tokens == @fallback.output_reserve_tokens
      assert budget.output_limit_parameter == :max_tokens
    end
  end

  test "exact config overrides take precedence and retain unspecified fallback fields" do
    overrides = %{
      zai: %{
        "glm-4.7" => %{context_window_tokens: 64_000, output_reserve_tokens: 8_000}
      }
    }

    budget = ModelBudget.resolve(:zai, "glm-4.7", @fallback, overrides)

    assert budget == %ModelBudget{
             max_prompt_bytes: 2_000_000,
             context_window_tokens: 64_000,
             output_reserve_tokens: 8_000,
             output_limit_parameter: :max_tokens
           }
  end

  test "validates the final resolved reserve against context" do
    overrides = %{fixture: %{"small" => %{context_window_tokens: 8_000}}}

    assert_raise ArgumentError, ~r/output_reserve_tokens.*less than context_window_tokens/, fn ->
      ModelBudget.resolve(:fixture, "small", @fallback, overrides)
    end
  end
end
