defmodule ReyCode.Provider.OpenAICompatible.ProfileTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.ModelBudget
  alias ReyCode.Provider.OpenAICompatible.Profile
  alias ReyCode.RuntimeConfig

  test "resolves exact model overrides over unchanged profile fallback fields" do
    config =
      RuntimeConfig.fresh(
        openai_compatible_providers: [
          %{
            id: :fixture,
            name: "Fixture",
            base_url: "https://fixture.example.test/v1",
            key_env: "FIXTURE_API_KEY",
            max_prompt_bytes: 96_000,
            context_window_tokens: 48_000,
            output_reserve_tokens: 8_000
          }
        ],
        openai_compatible_model_budget_overrides: %{
          fixture: %{"model-a" => %{context_window_tokens: 64_000}}
        }
      )

    assert {:ok, profile} = Profile.fetch(:fixture, config.open_ai)

    assert Profile.model_budget(profile, "model-a", config.open_ai) == %ModelBudget{
             max_prompt_bytes: 96_000,
             context_window_tokens: 64_000,
             output_reserve_tokens: 8_000
           }

    assert Profile.model_budget(profile, "MODEL-A", config.open_ai) == %ModelBudget{
             max_prompt_bytes: 96_000,
             context_window_tokens: 48_000,
             output_reserve_tokens: 8_000
           }

    assert profile.max_prompt_bytes == 96_000
    assert profile.context_window_tokens == 48_000
    assert profile.output_reserve_tokens == 8_000
  end
end
