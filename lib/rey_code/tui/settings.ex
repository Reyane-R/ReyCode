defmodule ReyCode.TUI.Settings do
  @moduledoc "State and input handling for the agent model settings wizard."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
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

  def handle_input(key, %{assigns: %{settings: %{step: :models}}} = term)
      when key in ["Backspace", "\x7F"] do
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

  @doc "Returns the initial settings-wizard state for an optional session."
  @spec initial(String.t() | nil) :: map()
  def initial(session_id \\ nil) do
    %{
      step: :participants,
      index: 0,
      participant_ids: [],
      session_id: session_id,
      query: "",
      provider: nil,
      onboarding?: false
    }
  end

  @doc "Opens the settings wizard for the current session."
  @spec open(map()) :: map()
  def open(term) do
    Component.assign(term,
      modal: :settings,
      settings: initial(term.assigns.selected_session_id),
      notice: nil
    )
  end

  @doc "Opens runtime selection for one newly created task participant."
  @spec open_for(map(), String.t()) :: map()
  def open_for(term, participant_id) do
    settings = %{
      initial(term.assigns.selected_session_id)
      | step: :providers,
        participant_ids: [participant_id]
    }

    Component.assign(term, modal: :settings, settings: settings, notice: nil)
  end

  @doc "Opens the provider/model path for an unconfigured first-run Primary Assistant."
  @spec open_first_run(map()) :: map()
  def open_first_run(term) do
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]
    primary = Enum.find(session.participants, &(&1.kind == :primary))

    settings = %{
      initial(term.assigns.selected_session_id)
      | step: :providers,
        participant_ids: [primary.id],
        onboarding?: true
    }

    Component.assign(term, modal: :settings, settings: settings, notice: nil)
  end

  @doc "Whether the durable projection is a pristine Session needing Primary runtime setup."
  @spec first_run_required?(map(), String.t() | nil) :: boolean()
  def first_run_required?(%{sessions: sessions}, selected_id) do
    session = Map.get(sessions, selected_id)
    primary = session && Enum.find(session.participants, &(&1.kind == :primary))

    not is_nil(primary) and session.message_order == [] and runtime_missing?(primary)
  end

  @doc "Opens model confirmation for one revalidated provider/model."
  @spec open_at(map(), atom(), String.t()) :: map()
  def open_at(term, provider, model) do
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]
    primary = Enum.find(session.participants, &(&1.kind == :primary))
    provider_entry = Map.get(term.assigns.providers, provider)

    if (primary && provider_entry && provider_entry.status == :configured) and
         model in provider_entry.models do
      settings = %{
        initial(term.assigns.selected_session_id)
        | step: :models,
          participant_ids: [primary.id],
          provider: provider,
          index: Enum.find_index(provider_entry.models, &(&1 == model)) || 0
      }

      Component.assign(term, modal: :settings, slash: nil, settings: settings, notice: nil)
    else
      term
      |> open()
      |> Component.assign(notice: "The selected model is no longer available")
    end
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
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]
    option = Enum.at(participant_options(session, term.assigns.mode), term.assigns.settings.index)

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

  def back(%{assigns: %{settings: %{step: :providers, onboarding?: true}}} = term) do
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

  @doc "Returns configurable agent options for the current session."
  @spec participant_options(map(), atom()) :: [map()]
  def participant_options(session, _mode) do
    participants = Enum.reject(session.participants, &(Map.get(&1, :kind) == :legacy))

    [%{label: "All agents", ids: Enum.map(participants, & &1.id)}] ++
      Enum.map(participants, &%{label: &1.name, ids: [&1.id]})
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
    term.assigns.projection.sessions[term.assigns.selected_session_id]
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
    case Engine.configure_participants(
           term.assigns.settings.session_id,
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

  defp runtime_missing?(nil), do: true

  defp runtime_missing?(%{provider: provider})
       when provider in [nil, :unconfigured, "unconfigured"],
       do: true

  defp runtime_missing?(%{provider: provider}) when provider in [:simulator, "simulator"],
    do: false

  defp runtime_missing?(%{model: model}),
    do: not is_binary(model) or String.trim(model) == ""

  defp update(term, update) do
    Component.assign(term, settings: update.(term.assigns.settings))
  end

  defp provider_models(providers, provider) do
    case providers do
      %{^provider => %{models: model_options}} -> model_options
      _ -> []
    end
  end
end
