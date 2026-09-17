defmodule ReyCode.Orchestration.SpendTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Invocation,
    Participant,
    ProviderRound,
    Spend
  }

  defp priced_invocation(overrides \\ %{}) do
    base = %{
      id: "inv-1",
      participant: %Participant{id: "p1", name: "Luna", model: "GLM-4.6"},
      rounds: [
        %ProviderRound{
          index: 0,
          usage: %{"prompt_tokens" => 100_000, "completion_tokens" => 50_000}
        }
      ]
    }

    struct(Invocation, Map.merge(base, overrides))
  end

  test "built-in rates cover GLM and DeepSeek list prices" do
    rates = Spend.built_in()
    assert rates["glm-4.6"] == %{input_per_mtok: 0.6, output_per_mtok: 2.2}
    assert rates["glm-5.3-flash"] == %{input_per_mtok: 0.15, output_per_mtok: 0.5}
    assert rates["deepseek-v4-pro"] == %{input_per_mtok: 1.32, output_per_mtok: 3.96}
    assert rates["glm-4.7-flash"] == %{input_per_mtok: 0.0, output_per_mtok: 0.0}
  end

  test "rate lookup is case-insensitive and nil-safe" do
    rates = Spend.built_in()
    assert Spend.rate_for(rates, " GLM-4.6 ") == rates["glm-4.6"]
    assert Spend.rate_for(rates, "mystery-model") == nil
    assert Spend.rate_for(rates, nil) == nil
  end

  test "round cost prices known input and output splits" do
    rate = %{input_per_mtok: 0.6, output_per_mtok: 2.2}

    assert Spend.round_cost_usd(
             %{"prompt_tokens" => 1_000_000, "completion_tokens" => 500_000},
             rate
           ) == 1.7

    assert Spend.round_cost_usd(
             %{"input_tokens" => 1_000_000, "output_tokens" => 1_000_000},
             rate
           ) == 2.8
  end

  test "round cost fails closed on unknown shapes" do
    rate = %{input_per_mtok: 0.6, output_per_mtok: 2.2}
    assert Spend.round_cost_usd(nil, rate) == nil
    assert Spend.round_cost_usd(%{"total_tokens" => 25_000}, rate) == nil
    assert Spend.round_cost_usd(%{"prompt_tokens" => 100}, rate) == nil
    assert Spend.round_cost_usd(%{"completion_tokens" => 100}, rate) == nil

    assert Spend.round_cost_usd(
             %{"prompt_tokens" => -1, "completion_tokens" => 0},
             rate
           ) == nil
  end

  test "primary token keys win over aliases instead of double counting" do
    rate = %{input_per_mtok: 1.0, output_per_mtok: 1.0}

    cost =
      Spend.round_cost_usd(
        %{
          "prompt_tokens" => 1_000_000,
          "input_tokens" => 5_000_000,
          "completion_tokens" => 0,
          "output_tokens" => 0
        },
        rate
      )

    assert cost == 1.0
  end

  test "session cost sums rounds per invocation at list prices" do
    first = priced_invocation()
    second = priced_invocation(%{id: "inv-2"})

    assert {:ok, usd} = Spend.session_cost_usd([first, second], Spend.built_in())
    assert_in_delta usd, 0.34, 1.0e-9
  end

  test "session cost falls back to invocation usage when rounds carry none" do
    invocation =
      priced_invocation(%{
        rounds: [%ProviderRound{index: 0, usage: nil}],
        usage: %{"input_tokens" => 1_000_000, "output_tokens" => 0}
      })

    assert Spend.session_cost_usd([invocation], Spend.built_in()) == {:ok, 0.6}
  end

  test "session cost fails closed for unknown models and unsplit usage" do
    unknown_model =
      priced_invocation(%{participant: %Participant{id: "p", name: "X", model: "mystery"}})

    assert Spend.session_cost_usd([unknown_model], Spend.built_in()) == :unavailable

    no_model = priced_invocation(%{participant: %Participant{id: "p", name: "X"}})
    assert Spend.session_cost_usd([no_model], Spend.built_in()) == :unavailable

    unsplit =
      priced_invocation(%{
        rounds: [%ProviderRound{index: 0, usage: %{"total_tokens" => 25_000}}]
      })

    assert Spend.session_cost_usd([unsplit], Spend.built_in()) == :unavailable

    partially_priced = [priced_invocation(), unknown_model]
    assert Spend.session_cost_usd(partially_priced, Spend.built_in()) == :unavailable
  end

  test "session cost is unavailable without any usage and reports free models as zero" do
    assert Spend.session_cost_usd([], Spend.built_in()) == :unavailable

    assert Spend.session_cost_usd([priced_invocation(%{rounds: []})], Spend.built_in()) ==
             :unavailable

    free =
      priced_invocation(%{participant: %Participant{id: "p", name: "X", model: "glm-4.7-flash"}})

    assert Spend.session_cost_usd([free], Spend.built_in()) == {:ok, 0.0}
  end

  test "pricing.json overrides replace built-in entries and skip invalid ones" do
    path = tmp_path("pricing")

    File.write!(
      path,
      Jason.encode!(%{
        "GLM-4.6" => %{"input_per_mtok" => 9.0, "output_per_mtok" => 9.0},
        "custom-model" => %{"input_per_mtok" => 1, "output_per_mtok" => 2},
        "bogus" => %{"input_per_mtok" => "many"}
      })
    )

    rates = Spend.resolve(path)
    assert rates["glm-4.6"] == %{input_per_mtok: 9.0, output_per_mtok: 9.0}
    assert rates["custom-model"] == %{input_per_mtok: 1, output_per_mtok: 2}
    assert rates["glm-5.3"] == Spend.built_in()["glm-5.3"]
  end

  test "malformed pricing files fail closed to built-in rates" do
    invalid_json = tmp_path("pricing-bad")
    File.write!(invalid_json, "not json")
    assert Spend.resolve(invalid_json) == Spend.built_in()

    not_an_object = tmp_path("pricing-array")
    File.write!(not_an_object, "[]")
    assert Spend.resolve(not_an_object) == Spend.built_in()

    oversized = tmp_path("pricing-huge")

    File.write!(
      oversized,
      Jason.encode!(%{
        "model" => %{
          "input_per_mtok" => 1,
          "output_per_mtok" => 1,
          "padding" => String.duplicate("x", 40_000)
        }
      })
    )

    assert Spend.resolve(oversized) == Spend.built_in()

    assert Spend.resolve(tmp_path("pricing-absent")) == Spend.built_in()
  end

  test "labels and formatting render adaptive decimals" do
    priced = [priced_invocation()]
    assert Spend.label(priced, Spend.built_in()) == "$0.17"
    assert Spend.label([], Spend.built_in()) == "—"

    assert Spend.format_usd(0.004) == "0.0040"
    assert Spend.format_usd(1.5) == "1.50"
    assert Spend.format_usd(0) == "0.0000"
  end

  defp tmp_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "reycode-spend-#{kind}-#{System.unique_integer([:positive])}.json"
    )
  end
end
