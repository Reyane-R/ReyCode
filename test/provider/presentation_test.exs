defmodule ReyCode.Provider.PresentationTest do
  use ExUnit.Case, async: true

  alias ReyCode.Failure
  alias ReyCode.Provider.Presentation

  describe "runtime_label/2" do
    test "retired CLI assignments explain how to reconnect" do
      for provider <- [:opencode, :omp, :open_code] do
        label = Presentation.runtime_label(%{provider: provider, model: "old/model"}, %{})
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

  test "missing credentials require a restart rather than promising shell exports can refresh" do
    entry = %{
      id: :deepseek,
      status: :available,
      failure: Failure.new(:missing_credentials, "missing")
    }

    for help <- [Presentation.selection_help(entry), Presentation.unavailable_help(entry)] do
      assert help =~ "DEEPSEEK_API_KEY"
      assert String.downcase(help) =~ "restart"
      refute help =~ "press R"
    end
  end

  test "keyless profiles recover through their server, never an empty credential name" do
    for id <- [:ollama, :lmstudio], status <- [:available, :error] do
      entry = %{
        id: id,
        status: status,
        failure: Failure.new(:provider_unavailable, "connection refused")
      }

      for help <- [Presentation.selection_help(entry), Presentation.unavailable_help(entry)] do
        assert String.downcase(help) =~ "server"
        assert help =~ "recheck"
        refute help =~ "API key"
        refute help =~ "Set "
      end
    end
  end

  test "authentication recovery depends on whether the provider sends credentials" do
    failure = Failure.new(:authentication_failed, "HTTP 401", false, 401)
    keyed = %{id: :deepseek, status: :error, failure: failure}
    local = %{id: :ollama, status: :error, failure: failure}

    assert Presentation.selection_help(keyed) =~ "DEEPSEEK_API_KEY"
    assert String.downcase(Presentation.selection_help(keyed)) =~ "restart"
    assert Presentation.selection_help(local) =~ "access settings"
    refute Presentation.selection_help(local) =~ "Set "
    refute Presentation.selection_help(local) =~ "restart ReyCode"
  end

  test "a reachable empty server needs a model, not new credentials" do
    entry = %{id: :ollama, status: :configured, models: []}
    help = Presentation.selection_help(entry)
    assert help =~ "model"
    assert help =~ "load"
    assert help =~ "recheck"
    refute help =~ "API key"
    assert Presentation.unavailable_help(entry) == help
    refute Presentation.ready?(entry, %{model: "llama3"})
  end

  test "request diagnostics are available separately from recovery guidance" do
    failure =
      Failure.new(:request_failed, "Model list request: request_failed (HTTP 404)", false, 404)

    entry = %{id: :deepseek, status: :error, failure: failure, error: failure.message}
    help = Presentation.selection_help(entry)
    refute help =~ failure.message
    assert help =~ "configuration"
    assert help =~ "recheck"
    assert Presentation.details(entry) == failure.message
    assert Presentation.details(%{id: :deepseek, status: :configured}) == nil
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
