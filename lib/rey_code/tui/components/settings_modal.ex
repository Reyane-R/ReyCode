defmodule ReyCode.TUI.Components.SettingsModal do
  @moduledoc "Renders the agent model settings wizard."

  use Breeze.Component

  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.{Notice, Settings}

  attr :term, :map, required: true

  @doc "Renders the settings wizard for the current session."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-2">
      <box class="inline w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">{title(@term.settings)}</box>
        <box class="w-full text-right text-muted">{header_controls(@term.settings)}</box>
      </box>
      <box class="pt-1 text-muted">{step_label(@term.settings.step)}</box>
      <box :if={@term.settings.onboarding?} class="pt-1 text-muted">
        Choose a provider runtime, then select the model the Assistant should use.
      </box>
      <box :if={@term.settings.step == :participants} class="pt-2 w-full">
        <box class="font-bold">Choose an agent</box>
        <box
          :for={{option, index} <- Enum.with_index(Settings.participant_options(@term.session, @term.mode))}
          class={row_class(index, @term.settings.index)}
        >
          {marker(index, @term.settings.index)} {option.label}
        </box>
      </box>
      <box :if={@term.settings.step == :providers} class="pt-2 w-full">
        <box class="font-bold">Select a runtime</box>
        <box
          :for={{provider, index} <- Enum.with_index(Settings.provider_options(@term.providers))}
          class={row_class(index, @term.settings.index)}
        >
          {marker(index, @term.settings.index)} {provider.name} {Presentation.status_label(provider)}
        </box>
        <box class="pt-2 text-muted">
          {clip(
            Presentation.selection_help(
              Enum.at(Settings.provider_options(@term.providers), @term.settings.index)
            ),
            @term.breeze.terminal.width
          )}
        </box>
      </box>
      <box :if={@term.settings.step == :models} class="pt-2 w-full">
        <box class="font-bold">Select a model</box>
        <box class="text-muted">
          Filter: {@term.settings.query}  (type to search, Backspace clears)
        </box>
        <box
          :for={{model, index} <- Settings.visible_models(
      @term.providers,
      @term.settings,
      @term.breeze.terminal.height
    )}
          class={row_class(index, @term.settings.index)}
        >
          {marker(index, @term.settings.index)} {ReyCode.TUI.ModelPicker.display_label(model, @term.breeze.terminal.width - 4)}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-2 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {clip(@term.notice.message, @term.breeze.terminal.width)}
      </box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select</box>
    </box>
    """
  end

  defp title(%{onboarding?: true}), do: "Set up your Assistant"
  defp title(_settings), do: "Configure agents"

  defp header_controls(%{onboarding?: true, step: :providers}),
    do: "Esc close   R recheck   D details"

  defp header_controls(%{step: :providers}), do: "Esc back   R recheck   D details"
  defp header_controls(_settings), do: "Esc back"

  defp step_label(:participants), do: "choose agents"
  defp step_label(:providers), do: "choose runtime"
  defp step_label(:models), do: "choose model"

  # Breeze clips overflow at the cell boundary without a marker; ending on an
  # ellipsis keeps long provider guidance visibly bounded instead of cut.
  defp clip(text, width) when is_binary(text) and is_integer(width) do
    max_graphemes = max(width - 8, 16)

    if String.length(text) <= max_graphemes do
      text
    else
      String.slice(text, 0, max_graphemes - 1) <> "…"
    end
  end

  defp clip(nil, _width), do: ""

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"

  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
