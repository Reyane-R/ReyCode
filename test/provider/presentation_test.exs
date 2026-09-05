defmodule ReyCode.Provider.PresentationTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.Presentation

  describe "runtime_label/2" do
    test "formats unconfigured and simulator runtimes" do
      assert Presentation.runtime_label(%{provider: :unconfigured, model: nil}, %{}) ==
               "Model API · not configured"

      assert Presentation.runtime_label(%{provider: :simulator, model: nil}, %{}) ==
               "Simulator (test only)"
    end

    test "retired CLI assignments explain how to reconnect" do
      for provider <- [:opencode, :omp, :open_code] do
        label = Presentation.runtime_label(%{provider: provider, model: "old/model"}, %{})
        assert label =~ "retired"
        assert label =~ "/connect"
      end
    end

    test "uses API provider display names and short model names" do
      assert Presentation.runtime_label(
               %{provider: :deepseek, model: "deepseek/deepseek-chat"},
               %{}
             ) == "DeepSeek · deepseek-chat"

      assert Presentation.provider_name(:deepseek) == "DeepSeek"
      assert Presentation.provider_name(:unconfigured) == nil
      assert Presentation.short_model("openrouter/qwen/qwen3") == "qwen3"
    end
  end

  test "formats compact runtime labels" do
    assert Presentation.short_runtime_label(%{provider: :unconfigured}) == "not configured"
    assert Presentation.short_runtime_label(%{provider: :simulator}) == "simulator"

    assert Presentation.short_runtime_label(%{
             provider: :opencode,
             model: "openai/gpt-5.6-sol"
           }) == "gpt-5.6-sol"

    assert Presentation.short_runtime_label(%{provider: :opencode, model: nil}) ==
             "model required"

    assert Presentation.short_runtime_label(%{provider: :deepseek}) == "deepseek"
  end

  test "maps every provider status label" do
    assert Presentation.status_label(nil) == "unknown"
    assert Presentation.status_label(%{status: :configured}) == "configured"
    assert Presentation.status_label(%{status: :checking}) == "checking"
    assert Presentation.status_label(%{status: :missing}) == "missing"
    assert Presentation.status_label(%{status: :available}) == "needs model or login"
    assert Presentation.status_label(%{status: :unchecked}) == "not checked"
    assert Presentation.status_label(%{status: :error}) == "error"
    assert Presentation.status_label(%{status: :custom}) == "custom"
  end

  test "presents provider selection and unavailable setup help" do
    assert Presentation.selection_help(%{
             id: :deepseek,
             name: "DeepSeek",
             status: :available
           }) =~ "DEEPSEEK_API_KEY"

    assert Presentation.unavailable_help(%{id: :opencode, status: :missing}) ==
             "Provider is not configured"

    assert Presentation.unavailable_help(%{id: :deepseek}) =~ "DEEPSEEK_API_KEY"
    assert Presentation.refresh_notice() == "Checking providers..."
  end

  test "requires configured catalog membership except for the simulator" do
    participant = %{provider: :opencode, model: "openai/gpt-5.6-sol"}

    assert Presentation.ready?(
             %{id: :opencode, status: :configured, models: [participant.model]},
             participant
           )

    refute Presentation.ready?(
             %{id: :opencode, status: :configured, models: ["openai/another-model"]},
             participant
           )

    refute Presentation.ready?(
             %{id: :opencode, status: :checking, models: [participant.model]},
             participant
           )

    refute Presentation.ready?(
             %{id: :opencode, status: :configured, models: [participant.model]},
             %{participant | model: nil}
           )

    assert Presentation.ready?(
             %{id: :simulator, status: :configured, models: []},
             %{provider: :simulator, model: nil}
           )

    refute Presentation.ready?(nil, participant)
  end

  test "styles ready, pending, and unavailable providers" do
    participant = %{provider: :opencode, model: "openai/gpt-5.6-sol"}

    assert Presentation.text_class(
             %{status: :configured, models: [participant.model]},
             participant
           ) == "px-1 text-success"

    assert Presentation.text_class(%{status: :checking, models: []}, participant) ==
             "px-1 text-warning"

    assert Presentation.text_class(%{status: :available, models: []}, participant) ==
             "px-1 text-warning"

    assert Presentation.text_class(%{status: :missing, models: []}, participant) ==
             "px-1 text-error"

    assert Presentation.text_class(nil, participant) == "px-1 text-error"
  end
end
