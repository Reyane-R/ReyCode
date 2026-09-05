defmodule ReyCode.TUI.SettingsTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{ModelPicker, Settings}

  test "initial/1 starts at participant selection for the requested room" do
    assert Settings.initial("room-1") == %{
             step: :participants,
             index: 0,
             participant_ids: [],
             session_id: "room-1",
             query: "",
             provider: nil,
             onboarding?: false
           }
  end

  test "first-run setup targets the pristine unconfigured Primary Assistant" do
    session = %{
      participants: [
        %{id: "builder", name: "Builder", kind: :primary, provider: :unconfigured, model: nil}
      ],
      message_order: []
    }

    projection = %{session_order: ["room-1"], sessions: %{"room-1" => session}}
    term = term(projection: projection)

    assert Settings.first_run_required?(projection, "room-1")

    opened = Settings.open_first_run(term)
    assert opened.assigns.modal == :settings
    assert opened.assigns.settings.step == :providers
    assert opened.assigns.settings.participant_ids == ["builder"]
    assert opened.assigns.settings.onboarding?

    closed = Settings.back(opened)
    assert closed.assigns.modal == nil
    assert closed.focused == "prompt"
  end

  test "first-run setup does not interrupt configured or used selected Sessions" do
    configured = %{
      participants: [
        %{id: "builder", kind: :primary, provider: :ollama, model: "openai/gpt"}
      ],
      message_order: []
    }

    projection = %{session_order: ["room-1"], sessions: %{"room-1" => configured}}
    refute Settings.first_run_required?(projection, "room-1")

    unconfigured =
      put_in(projection, [:sessions, "room-1", :participants, Access.at(0)], %{
        id: "builder",
        kind: :primary,
        provider: :unconfigured,
        model: nil
      })

    used = put_in(unconfigured, [:sessions, "room-1", :message_order], ["message-1"])
    refute Settings.first_run_required?(used, "room-1")

    multiple = %{unconfigured | session_order: ["room-1", "room-2"]}
    assert Settings.first_run_required?(multiple, "room-1")
  end

  test "move/2 wraps participant selection" do
    term = term()

    assert Settings.move(term, -1).assigns.settings.index == 2
    assert Settings.move(term, 1).assigns.settings.index == 1
  end

  test "confirm/1 advances from participants to providers" do
    term = put_in(term().assigns.settings.index, 1)
    result = Settings.confirm(term)

    assert result.assigns.settings.step == :providers
    assert result.assigns.settings.index == 0
    assert result.assigns.settings.participant_ids == ["builder"]
  end

  test "confirm/1 advances a configured provider to model selection" do
    settings = %{Settings.initial("room-1") | step: :providers}
    term = term(settings: settings)
    result = Settings.confirm(term)

    assert result.assigns.settings.step == :models
    assert result.assigns.settings.provider == :ollama
    assert result.assigns.settings.query == ""
  end

  test "open_at/3 revalidates and preselects one Primary model" do
    result = Settings.open_at(term(), :ollama, "openai/gpt")

    assert result.assigns.modal == :settings
    assert result.assigns.settings.step == :models
    assert result.assigns.settings.participant_ids == ["builder"]
    assert result.assigns.settings.provider == :ollama
    assert result.assigns.settings.index == 1
  end

  test "open_at/3 rejects a stale model into the regular settings flow" do
    result = Settings.open_at(term(), :ollama, "missing")

    assert result.assigns.settings.step == :participants
    assert result.assigns.notice == "The selected model is no longer available"
  end

  test "models/2 filters case-insensitively" do
    settings = %{Settings.initial() | provider: :ollama, query: "CLAUDE"}

    assert Settings.models(providers(), settings) == ["anthropic/claude"]
  end

  test "display_label keeps long model names on one terminal line" do
    label = "Ollama · local/deepseek/deepseek-v4-flash"
    display = ModelPicker.display_label(label, 18)

    assert String.length(display) == 18
    assert String.valid?(display)
    refute String.contains?(display, "\n")
    assert ModelPicker.display_label(label, 1) == "O"
  end

  test "back/1 closes the first step and restores prompt focus" do
    result = Settings.back(term())

    assert result.assigns.modal == nil
    assert result.assigns.notice == nil
    assert result.focused == "prompt"
  end

  test "back/1 returns from models to the selected provider" do
    settings = %{Settings.initial() | step: :models, provider: :deepseek, query: "chat"}
    term = term(settings: settings, providers: providers_with_deepseek())
    result = Settings.back(term)

    assert result.assigns.settings.step == :providers
    assert result.assigns.settings.index == 0
    assert result.assigns.settings.provider == :deepseek
    assert result.assigns.settings.query == ""
  end

  test "query editing resets the selected model" do
    settings = %{Settings.initial() | step: :models, query: "cla", index: 1}
    term = term(settings: settings)

    appended = Settings.append_query(term, "u")
    assert appended.assigns.settings.query == "clau"
    assert appended.assigns.settings.index == 0

    removed = Settings.backspace_query(appended)
    assert removed.assigns.settings.query == "cla"
    assert removed.assigns.settings.index == 0
  end

  test "terminal DEL edits the model query as Backspace" do
    key = Breeze.KeyDecoder.decode("\x7F")
    settings = %{Settings.initial() | step: :models, query: "ghfa", index: 1}

    assert key == "\x7F"
    assert {:noreply, result} = Settings.handle_input(key, term(settings: settings))
    assert result.assigns.settings.query == "ghf"
    assert result.assigns.settings.index == 0
  end

  defp term(overrides \\ []) do
    session = %{
      participants: [
        %{id: "builder", name: "Builder", kind: :primary},
        %{id: "critic", name: "Critic", kind: :task}
      ]
    }

    assigns = %{
      modal: :settings,
      notice: nil,
      mode: :compare,
      selected_session_id: "room-1",
      projection: %{sessions: %{"room-1" => session}},
      provider_catalog: nil,
      providers: providers(),
      settings: Settings.initial("room-1")
    }

    %Breeze.Term{assigns: Map.merge(assigns, Map.new(overrides))}
  end

  defp providers do
    %{
      ollama: %{
        id: :ollama,
        name: "Ollama",
        status: :configured,
        models: ["anthropic/claude", "openai/gpt"]
      }
    }
  end

  defp providers_with_deepseek do
    Map.put(providers(), :deepseek, %{
      id: :deepseek,
      name: "DeepSeek",
      status: :configured,
      models: ["deepseek-chat"]
    })
  end
end
