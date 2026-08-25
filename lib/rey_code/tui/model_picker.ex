defmodule ReyCode.TUI.ModelPicker do
  @moduledoc "Owns one-step provider/model selection for the session's Primary Assistant."

  use Breeze.Component
  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.SlashPalette

  @spec initial() :: map()
  def initial, do: %{index: 0}

  @spec open(map()) :: map()
  def open(term) do
    case entries(term_assigns(term).providers) do
      [] ->
        SlashPalette.close(term, "No providers configured — run /connect first")

      _entries ->
        term
        |> Component.assign(
          modal: :model_picker,
          model_picker: initial(),
          slash: nil,
          notice: nil
        )
        |> View.focus("prompt")
    end
  end

  @doc "Returns one selectable row per configured provider model, name-ordered."
  @spec entries(map()) :: [map()]
  def entries(providers) do
    providers
    |> Map.values()
    |> Enum.filter(&(&1.status == :configured))
    |> Enum.sort_by(& &1.name)
    |> Enum.flat_map(&provider_rows/1)
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    assigns = term.assigns
    count = length(entries(assigns.providers))
    index = Integer.mod(assigns.model_picker.index + offset, count)
    {:noreply, Component.assign(term, model_picker: %{index: index})}
  end

  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    assigns = term.assigns
    entry = Enum.at(entries(assigns.providers), assigns.model_picker.index)

    with %{provider: provider, model: model, label: label} <- entry,
         %{} = room <- assigns.projection.rooms[assigns.selected_room_id],
         %{} = primary <- primary_participant(room) do
      configure(term, entry, provider, model, label, primary)
    else
      _other -> {:noreply, Component.assign(term, notice: "No Assistant configured")}
    end
  end

  defp configure(term, _entry, provider, model, label, primary) do
    case Engine.configure_participants(
           term.assigns.selected_room_id,
           [primary.id],
           provider,
           model,
           term.assigns.engine
         ) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(modal: nil, model_picker: initial(), notice: "Model set to #{label}")
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not set model: #{reason}")}
    end
  end

  defp cancel(term) do
    term
    |> Component.assign(modal: nil, model_picker: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp primary_participant(room) do
    Enum.find(room.participants, &(&1.kind == :primary))
  end

  defp provider_rows(%{models: []} = provider),
    do: [%{provider: provider.id, model: nil, label: provider.name}]

  defp provider_rows(provider) do
    Enum.map(provider.models, fn model ->
      %{provider: provider.id, model: model, label: "#{provider.name} · #{model}"}
    end)
  end

  defp term_assigns(%{assigns: assigns}), do: assigns
  defp term_assigns(assigns), do: assigns

  attr :term, :map, required: true

  @doc "Renders the Assistant model list."
  def modal(assigns) do
    assigns = Component.assign(assigns, selected: assigns_index(Map.get(assigns, :term, assigns)))

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Assistant model</box>
        <box class="text-muted">One selection updates the Primary Assistant immediately.</box>
      </box>
      <box class="pt-3 w-full">
        <box
          :for={{entry, index} <- Enum.with_index(entries(@term.providers))}
          class={row_class(index, @selected)}
        >
          {marker(index, @selected)} {entry.label}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select   Esc cancel</box>
    </box>
    """
  end

  defp assigns_index(term) do
    case term do
      %{assigns: %{model_picker: %{index: index}}} -> index
      %{model_picker: %{index: index}} -> index
      _other -> 0
    end
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
