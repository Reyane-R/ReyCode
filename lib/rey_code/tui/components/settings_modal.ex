defmodule ReyCode.TUI.Components.SettingsModal do
  @moduledoc "Renders the room-agent settings wizard."

  use Breeze.Component

  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.Settings

  attr :term, :map, required: true

  @doc "Renders the settings wizard for the active room."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-2">
      <box class="inline w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Configure room agents</box>
        <box class="w-full text-right text-muted">{header_controls(@term.settings.step)}</box>
      </box>
      <box class="pt-1 text-muted">#{@term.room.slug}  /  {step_label(@term.settings.step)}</box>
      <box :if={@term.settings.step == :participants} class="pt-2 w-full">
        <box class="font-bold">Who should use this runtime?</box>
        <box
          :for={{option, index} <- Enum.with_index(Settings.participant_options(@term.room, @term.mode))}
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
          {Presentation.selection_help(
            Enum.at(Settings.provider_options(@term.providers), @term.settings.index)
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
          {marker(index, @term.settings.index)} {model}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select</box>
    </box>
    """
  end

  defp header_controls(:providers), do: "Esc back   R recheck"
  defp header_controls(_step), do: "Esc back"

  defp step_label(:participants), do: "choose agents"
  defp step_label(:providers), do: "choose runtime"
  defp step_label(:models), do: "choose model"

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"

  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
