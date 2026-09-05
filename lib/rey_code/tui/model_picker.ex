defmodule ReyCode.TUI.ModelPicker do
  @moduledoc "Owns one-step provider/model selection for the session's Primary Assistant."

  use Breeze.Component
  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.{Notice, SlashPalette}

  @spec initial() :: map()
  def initial, do: %{index: 0}

  @spec open(map()) :: map()
  def open(term) do
    case entries(term_assigns(term).providers) do
      [] ->
        SlashPalette.close(
          term,
          Notice.new(:warning, "No providers configured — run /connect first")
        )

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
         %{} = session <- assigns.projection.sessions[assigns.selected_session_id],
         %{} = primary <- primary_participant(session) do
      configure(term, entry, provider, model, label, primary)
    else
      _other ->
        {:noreply,
         Component.assign(term, notice: Notice.new(:warning, "No Assistant configured"))}
    end
  end

  @doc "Immediately selects one revalidated provider/model for the Primary Assistant."
  @spec select(map(), atom(), String.t()) :: {:noreply, map()}
  def select(term, provider, model) do
    assigns = term.assigns

    entry =
      Enum.find(entries(assigns.providers), fn entry ->
        entry.provider == provider and entry.model == model
      end)

    with %{} = selected <- entry,
         %{} = session <- assigns.projection.sessions[assigns.selected_session_id],
         %{} = primary <- primary_participant(session) do
      configure(term, selected, provider, model, selected.label, primary)
    else
      _other ->
        {:noreply,
         Component.assign(term,
           notice: Notice.new(:warning, "The selected model is no longer available")
         )}
    end
  end

  defp configure(term, _entry, provider, model, label, primary) do
    case Engine.configure_participants(
           term.assigns.selected_session_id,
           [primary.id],
           provider,
           model,
           term.assigns.engine
         ) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(
           modal: nil,
           model_picker: initial(),
           notice: Notice.new(:success, "Model set to #{label}")
         )
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply,
         Component.assign(term, notice: Notice.new(:error, "Could not set model: #{reason}"))}
    end
  end

  defp cancel(term) do
    term
    |> Component.assign(modal: nil, model_picker: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp primary_participant(session) do
    Enum.find(session.participants, &(&1.kind == :primary))
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

  def modal(assigns) do
    assigns = Component.assign(assigns, selected: assigns_index(Map.get(assigns, :term, assigns)))

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-2 overflow-hidden">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Assistant model</box>
        <box class="text-muted">One selection updates the Primary Assistant immediately.</box>
      </box>
      <box class="pt-3 w-full overflow-hidden">
        <box
          :for={{entry, index} <- Enum.with_index(entries(@term.providers))}
          class={row_class(index, @selected)}
        >
          {marker(index, @selected)} {display_label(entry.label, @term.breeze.terminal.width - 4)}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-2 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select   Esc cancel</box>
    </box>
    """
  end

  @doc "Truncates a model row to one terminal line without splitting UTF-8."
  @spec display_label(String.t(), integer()) :: String.t()
  def display_label(label, width) when width <= 1, do: String.slice(label, 0, 1)

  def display_label(label, width) do
    graphemes = String.graphemes(label)

    if length(graphemes) <= width do
      label
    else
      left = max(div(width - 1, 2), 0)
      right = max(width - 1 - left, 0)

      (Enum.slice(graphemes, 0, left) ++ ["…"] ++ Enum.slice(graphemes, -right, right))
      |> IO.iodata_to_binary()
    end
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
