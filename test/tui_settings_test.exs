defmodule ReyCode.TUI.SettingsTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{ModelPicker, Settings}

  test "initial/1 starts at participant selection for the requested room" do
    assert Settings.initial("room-1") == %{
             step: :participants,
             index: 0,
             participant_ids: [],
             room_id: "room-1",
             query: "",
             provider: nil
           }
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
    assert result.assigns.settings.provider == :opencode
    assert result.assigns.settings.query == ""
  end

  test "open_at/3 revalidates and preselects one Primary model" do
    result = Settings.open_at(term(), :opencode, "openai/gpt")

    assert result.assigns.modal == :settings
    assert result.assigns.settings.step == :models
    assert result.assigns.settings.participant_ids == ["builder"]
    assert result.assigns.settings.provider == :opencode
    assert result.assigns.settings.index == 1
  end

  test "open_at/3 rejects a stale model into the regular settings flow" do
    result = Settings.open_at(term(), :opencode, "missing")

    assert result.assigns.settings.step == :participants
    assert result.assigns.notice == "The selected model is no longer available"
  end

  test "models/2 filters case-insensitively" do
    settings = %{Settings.initial() | provider: :opencode, query: "CLAUDE"}

    assert Settings.models(providers(), settings) == ["anthropic/claude"]
  end

  test "display_label keeps long model names on one terminal line" do
    label = "OMP · omp/deepseek/deepseek-v4-flash"
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
    assert result.assigns.settings.index == 1
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

  defp term(overrides \\ []) do
    room = %{
      participants: [
        %{id: "builder", name: "Builder", kind: :primary},
        %{id: "critic", name: "Critic", kind: :task}
      ]
    }

    assigns = %{
      modal: :settings,
      notice: nil,
      mode: :compare,
      selected_room_id: "room-1",
      projection: %{rooms: %{"room-1" => room}},
      provider_catalog: nil,
      providers: providers(),
      settings: Settings.initial("room-1")
    }

    %Breeze.Term{assigns: Map.merge(assigns, Map.new(overrides))}
  end

  defp providers do
    %{
      opencode: %{
        id: :opencode,
        name: "OpenCode",
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
