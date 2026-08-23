defmodule ReyCode.TUI do
  @moduledoc """
  The terminal-native project room client.

  Owns global navigation, application lifecycle, and the composer. Each open
  modal delegates input, submission, focus, and rendering to its feature
  module through `ReyCode.TUI.Components.Modals`.
  """

  use Breeze.View

  alias ReyCode.Orchestration.Engine
  alias ReyCode.Orchestration.Squad

  alias ReyCode.TUI.Components.Modals

  alias ReyCode.TUI.{NewRoom, Render, Settings, SlashPalette, State}

  @modes [:compare, :debate, :fan_out, :squad]

  @doc "Global keybindings shared by the application and tests."
  def global_keybindings do
    [
      {"Tab", "Move focus", &switch_focus/2},
      {"^N", "New room", &open_new_room/2},
      {"^O", "Mode", &cycle_mode/2},
      {"^P", "Commands", &open_command_palette/2},
      {"^S", "Send", &submit/2},
      {"^R", "Next room", &next_room/2},
      {"^G", "Configure agents", &open_provider_settings/2},
      {"^T", "Theme", &__MODULE__.cycle_theme/2},
      {"^Q", "Quit", &quit/2}
    ]
  end

  def cycle_theme(event, term) do
    Breeze.View.cycle_theme(event, term,
      themes: [
        {"reycode", ReyCode.Theme.default()},
        :nord,
        {:gruvbox, Breeze.Theme.builtin(:gruvbox, :dark)}
      ]
    )
  end

  @doc "Moves focus; active modals own their focus behavior."
  def switch_focus(_event, %{assigns: %{modal: modal}} = term) when not is_nil(modal),
    do: {:noreply, Modals.module!(modal).focus(term)}

  def switch_focus(_event, term) do
    show_sidebar? = State.show_sidebar?(term.assigns.breeze.terminal.width)

    next =
      case term.focused do
        "prompt" when not show_sidebar? -> State.timeline_id(term.assigns.selected_room_id)
        "prompt" -> "rooms"
        "rooms" -> State.timeline_id(term.assigns.selected_room_id)
        _ -> "prompt"
      end

    {:noreply, focus(term, next)}
  end

  def cycle_mode(_event, %{assigns: %{modal: modal}} = term) when not is_nil(modal),
    do: {:noreply, term}

  def cycle_mode(_event, term), do: {:noreply, cycle_mode_state(term)}

  @doc "Cycles the orchestration mode of the composer."
  def cycle_mode_state(term) do
    index = Enum.find_index(@modes, &(&1 == term.assigns.mode)) || 0
    mode = Enum.at(@modes, rem(index + 1, length(@modes)))
    assign(term, mode: mode)
  end

  def next_room(_event, %{assigns: %{modal: modal}} = term) when not is_nil(modal),
    do: {:noreply, term}

  def next_room(_event, term) do
    {:noreply, State.select_adjacent_room(term, 1)}
  end

  def open_provider_settings(_event, %{assigns: %{modal: modal}} = term)
      when not is_nil(modal),
      do: {:noreply, term}

  def open_provider_settings(_event, term) do
    {:noreply, Settings.open(term)}
  end

  def open_new_room(_event, %{assigns: %{modal: modal}} = term) when not is_nil(modal),
    do: {:noreply, term}

  def open_new_room(_event, term) do
    {:noreply, NewRoom.open(term)}
  end

  def open_command_palette(_event, %{assigns: %{modal: nil}} = term) do
    {:noreply, SlashPalette.open(term)}
  end

  def open_command_palette(_event, term), do: {:noreply, term}

  @doc "Submits the active modal or the composer draft."
  def submit(_event, %{assigns: %{modal: modal}} = term) when not is_nil(modal),
    do: Modals.module!(modal).submit(term)

  def submit(_event, %{assigns: %{modal: nil}} = term) do
    draft = Map.get(term.assigns.drafts, term.assigns.selected_room_id, "")
    command = String.trim(draft)

    if String.starts_with?(command, "/") do
      SlashPalette.run_typed(term, command)
    else
      post_message(term, draft)
    end
  end

  def quit(_event, term) do
    server = self()

    Task.start(fn ->
      ref = Process.monitor(server)
      receive do: ({:DOWN, ^ref, :process, ^server, _reason} -> :ok)
      System.stop(0)
    end)

    {:stop, term}
  end

  defp post_message(term, draft) do
    case Engine.post_message(
           term.assigns.selected_room_id,
           draft,
           term.assigns.mode,
           term.assigns.engine
         ) do
      {:ok, _turn_id} ->
        drafts = Map.put(term.assigns.drafts, term.assigns.selected_room_id, "")
        {:noreply, assign(term, drafts: drafts, notice: nil)}

      {:error, :empty_message} ->
        {:noreply, assign(term, notice: "Write a message first")}

      {:error, {:squad_roles_unconfigured, role_ids}} ->
        names = Enum.map_join(role_ids, ", ", &Squad.role(&1).name)
        {:noreply, assign(term, notice: "Configure squad roles with Ctrl+G: #{names}")}

      {:error, {:participants_unconfigured, participant_ids}} ->
        {:noreply,
         assign(term,
           notice: "Configure room agents with Ctrl+G: #{Enum.join(participant_ids, ", ")}"
         )}

      {:error, reason} ->
        {:noreply, assign(term, notice: "Could not send: #{reason}")}
    end
  end

  @impl true
  def mount(opts, term), do: State.mount(opts, term)

  @impl true
  def render(assigns), do: assigns |> State.prepare_render() |> Render.render()

  @impl true
  def handle_event(:input, %{"key" => key}, %{assigns: %{modal: modal}} = term)
      when not is_nil(modal) do
    Modals.module!(modal).handle_input(key, term)
  end

  def handle_event(event, payload, %{assigns: %{modal: modal}} = term)
      when not is_nil(modal) do
    case Modals.module!(modal).handle_event(event, payload, term) do
      :unhandled -> do_handle_event(event, payload, term)
      result -> result
    end
  end

  def handle_event(event, payload, term), do: do_handle_event(event, payload, term)

  defp do_handle_event("prompt_changed", %{value: value}, term), do: prompt_changed(term, value)

  defp do_handle_event("prompt_submitted", %{value: value}, term) do
    term
    |> State.assign_draft(value)
    |> then(&submit(nil, &1))
  end

  defp do_handle_event(:input, %{"key" => key}, %{focused: "rooms"} = term)
       when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, State.select_adjacent_room(term, offset)}
  end

  defp do_handle_event(:input, %{"key" => "Enter"}, %{focused: "prompt"} = term) do
    submit(nil, term)
  end

  defp do_handle_event(_, _, term), do: {:noreply, term}

  defp prompt_changed(%{assigns: %{modal: modal}} = term, value) do
    if is_nil(modal) and String.starts_with?(value, "/") do
      {:noreply, SlashPalette.start(term, value)}
    else
      {:noreply, State.assign_draft(term, value)}
    end
  end

  @impl true
  def handle_info({:projection_snapshot, projection}, term) do
    {:noreply, State.projection_updated(term, projection)}
  end

  def handle_info({:provider_catalog_updated, providers}, term) do
    {:noreply, State.providers_updated(term, providers)}
  end
end
