defmodule ReyCode.TUI.Settings do
  @moduledoc """
  State, input handling, and rendering for the room-agent settings wizard.
  """

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Squad}
  alias ReyCode.Provider.{Catalog, Presentation, Registry}

  @doc "Keeps global focus unchanged while the wizard is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Confirms the wizard's selected option."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, confirm(term)}

  @doc "Handles one key press while the settings wizard is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, move(term, offset)}
  end

  def handle_input("Enter", term), do: {:noreply, confirm(term)}

  def handle_input(key, %{assigns: %{settings: %{step: :providers}}} = term)
      when key in ["r", "R"] do
    {:noreply, refresh(term)}
  end

  def handle_input("Backspace", %{assigns: %{settings: %{step: :models}}} = term) do
    {:noreply, backspace_query(term)}
  end

  def handle_input("Escape", term), do: {:noreply, back(term)}

  def handle_input(key, %{assigns: %{settings: %{step: :models}}} = term) do
    {:noreply, append_query(term, key)}
  end

  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the settings wizard declares none."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns the initial settings-wizard state for an optional room."
  @spec initial(String.t() | nil) :: map()
  def initial(room_id \\ nil) do
    %{
      step: :participants,
      index: 0,
      participant_ids: [],
      room_id: room_id,
      query: "",
      provider: nil
    }
  end

  @doc "Opens the settings wizard for the currently selected room."
  @spec open(map()) :: map()
  def open(term) do
    Component.assign(term,
      modal: :settings,
      settings: initial(term.assigns.selected_room_id),
      notice: nil
    )
  end

  @doc "Moves the selected option by an offset, wrapping at either end."
  @spec move(map(), integer()) :: map()
  def move(term, offset) do
    count = option_count(term)

    if count == 0 do
      term
    else
      update(term, fn settings ->
        %{settings | index: Integer.mod(settings.index + offset, count)}
      end)
    end
  end

  @doc "Confirms the selected option and advances or completes the wizard."
  @spec confirm(map()) :: map()
  def confirm(%{assigns: %{settings: %{step: :participants}}} = term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]
    option = Enum.at(participant_options(room, term.assigns.mode), term.assigns.settings.index)

    term
    |> update(fn settings ->
      %{settings | step: :providers, index: 0, participant_ids: option.ids}
    end)
    |> Component.assign(notice: nil)
  end

  def confirm(%{assigns: %{settings: %{step: :providers}}} = term) do
    case Enum.at(provider_options(term.assigns.providers), term.assigns.settings.index) do
      nil ->
        Component.assign(term, notice: "Select a provider runtime")

      %{status: :checking} = entry ->
        Component.assign(term, notice: "#{entry.name} is still being checked")

      %{status: status} = entry when status != :configured ->
        Component.assign(term, notice: Presentation.unavailable_help(entry))

      %{models: []} = entry ->
        Component.assign(term, notice: "No models available for #{entry.name}")

      %{id: id} ->
        term
        |> update(fn settings ->
          %{settings | step: :models, index: 0, query: "", provider: id}
        end)
        |> Component.assign(notice: nil)
    end
  end

  def confirm(%{assigns: %{settings: %{step: :models, provider: provider}}} = term) do
    model =
      Enum.at(models(term.assigns.providers, term.assigns.settings), term.assigns.settings.index)

    if model,
      do: save(term, provider, model),
      else: Component.assign(term, notice: "No models available")
  end

  @doc "Returns to the previous settings step or closes the wizard."
  @spec back(map()) :: map()
  def back(%{assigns: %{settings: %{step: :participants}}} = term) do
    term
    |> Component.assign(modal: nil, notice: nil)
    |> View.focus("prompt")
  end

  def back(%{assigns: %{settings: %{step: :providers}}} = term) do
    term
    |> update(fn settings -> %{settings | step: :participants, index: 0} end)
    |> Component.assign(notice: nil)
  end

  def back(%{assigns: %{settings: %{step: :models}}} = term) do
    provider = term.assigns.settings.provider

    provider_index =
      Enum.find_index(provider_options(term.assigns.providers), &(&1.id == provider)) || 0

    term
    |> update(fn settings ->
      %{settings | step: :providers, index: provider_index, query: ""}
    end)
    |> Component.assign(notice: nil)
  end

  @doc "Refreshes provider discovery while selecting a runtime."
  @spec refresh(map()) :: map()
  def refresh(term) do
    if get_in(term.assigns.providers, [:opencode, :status]) == :unchecked do
      Component.assign(term, notice: "Provider discovery is disabled")
    else
      Catalog.refresh(term.assigns.provider_catalog)
      Component.assign(term, notice: Presentation.refresh_notice())
    end
  end

  @doc "Removes the last model-filter character and resets the selection."
  @spec backspace_query(map()) :: map()
  def backspace_query(term) do
    query =
      String.slice(
        term.assigns.settings.query,
        0,
        max(String.length(term.assigns.settings.query) - 1, 0)
      )

    update(term, fn settings -> %{settings | query: query, index: 0} end)
  end

  @doc "Appends a printable character to the model filter."
  @spec append_query(map(), String.t()) :: map()
  def append_query(term, key) do
    if String.length(key) == 1 and key >= " " do
      update(term, fn settings -> %{settings | query: settings.query <> key, index: 0} end)
    else
      term
    end
  end

  @doc "Clamps the selected index after provider or model options change."
  @spec reconcile_options(map()) :: map()
  def reconcile_options(term) do
    count = option_count(term)

    update(term, fn settings ->
      %{settings | index: min(settings.index, max(count - 1, 0))}
    end)
  end

  @doc "Returns participant-selection options for the current orchestration mode."
  @spec participant_options(map(), atom()) :: [map()]
  def participant_options(_room, :squad) do
    [%{label: "All squad roles", ids: Enum.map(Squad.roles(), & &1.id)}] ++
      Enum.map(Squad.roles(), &%{label: &1.name, ids: [&1.id]})
  end

  def participant_options(room, _mode) do
    [%{label: "All agents", ids: Enum.map(room.participants, & &1.id)}] ++
      Enum.map(room.participants, &%{label: &1.name, ids: [&1.id]})
  end

  @doc "Returns configured provider entries in registry display order."
  @spec provider_options(map()) :: [map()]
  def provider_options(providers) do
    Registry.live_provider_ids()
    |> Enum.map(&providers[&1])
    |> Enum.reject(&is_nil/1)
  end

  @doc "Returns the filtered model options visible around the selected index."
  @spec visible_models(map(), map(), pos_integer()) :: [{String.t(), non_neg_integer()}]
  def visible_models(providers, settings, height) do
    model_options = models(providers, settings)
    count = max(height - 9, 3)

    start =
      settings.index
      |> Kernel.-(div(count, 2))
      |> max(0)
      |> min(max(length(model_options) - count, 0))

    model_options
    |> Enum.with_index()
    |> Enum.slice(start, count)
  end

  @doc "Returns provider models filtered by the settings query."
  @spec models(map(), map()) :: [String.t()]
  def models(providers, settings) do
    model_options = provider_models(providers, settings.provider)
    needle = settings.query |> String.trim() |> String.downcase()

    if needle == "" do
      model_options
    else
      Enum.filter(model_options, &String.contains?(String.downcase(&1), needle))
    end
  end

  defp option_count(%{assigns: %{settings: %{step: :participants}}} = term) do
    term.assigns.projection.rooms[term.assigns.selected_room_id]
    |> participant_options(term.assigns.mode)
    |> length()
  end

  defp option_count(%{assigns: %{settings: %{step: :providers}}} = term) do
    length(provider_options(term.assigns.providers))
  end

  defp option_count(%{assigns: %{settings: %{step: :models}}} = term) do
    length(models(term.assigns.providers, term.assigns.settings))
  end

  defp save(term, provider, model) do
    configure =
      if term.assigns.mode == :squad,
        do: &Engine.configure_squad_roles/5,
        else: &Engine.configure_participants/5

    case configure.(
           term.assigns.settings.room_id,
           term.assigns.settings.participant_ids,
           provider,
           model,
           term.assigns.engine
         ) do
      :ok ->
        term
        |> Component.assign(modal: nil, settings: initial(), notice: nil)
        |> View.focus("prompt")

      {:error, reason} ->
        Component.assign(term, notice: "Could not configure agents: #{reason}")
    end
  end

  defp update(term, update) do
    Component.assign(term, settings: update.(term.assigns.settings))
  end

  defp provider_models(providers, provider) do
    case providers do
      %{^provider => %{models: model_options}} -> model_options
      _ -> []
    end
  end

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
          :for={{option, index} <- Enum.with_index(participant_options(@term.room, @term.mode))}
          class={row_class(index, @term.settings.index)}
        >
          {marker(index, @term.settings.index)} {option.label}
        </box>
      </box>
      <box :if={@term.settings.step == :providers} class="pt-2 w-full">
        <box class="font-bold">Select a runtime</box>
        <box
          :for={{provider, index} <- Enum.with_index(provider_options(@term.providers))}
          class={row_class(index, @term.settings.index)}
        >
          {marker(index, @term.settings.index)} {provider.name} {Presentation.status_label(provider)}
        </box>
        <box class="pt-2 text-muted">
          {Presentation.selection_help(Enum.at(provider_options(@term.providers), @term.settings.index))}
        </box>
      </box>
      <box :if={@term.settings.step == :models} class="pt-2 w-full">
        <box class="font-bold">Select a model</box>
        <box class="text-muted">
          Filter: {@term.settings.query}  (type to search, Backspace clears)
        </box>
        <box
          :for={{model, index} <- visible_models(
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
