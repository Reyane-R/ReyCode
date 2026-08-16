defmodule ReyCode.TUI do
  @moduledoc "The terminal-native project room client."

  use Breeze.View

  alias ReyCode.Orchestration.Engine
  alias ReyCode.Orchestration.Squad

  alias ReyCode.TUI.{
    Cancellation,
    Directive,
    GateReview,
    NewRoom,
    Render,
    Settings,
    SlashPalette,
    SquadStatus,
    State,
    Workspace
  }

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

  def switch_focus(_event, %{assigns: %{modal: :new_room}} = term),
    do: {:noreply, NewRoom.focus(term)}

  def switch_focus(_event, %{assigns: %{modal: :settings}} = term), do: {:noreply, term}
  def switch_focus(_event, %{assigns: %{modal: :workspace}} = term), do: {:noreply, term}
  def switch_focus(_event, %{assigns: %{modal: :cancel}} = term), do: {:noreply, term}
  def switch_focus(_event, %{assigns: %{modal: :squad_dashboard}} = term), do: {:noreply, term}

  def switch_focus(_event, %{assigns: %{modal: :directive}} = term),
    do: {:noreply, Directive.focus(term)}

  def switch_focus(_event, %{assigns: %{modal: :gate_review}} = term), do: {:noreply, term}

  def switch_focus(_event, %{assigns: %{modal: :slash}} = term),
    do: {:noreply, SlashPalette.complete(term)}

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

  defp cycle_mode_state(term) do
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

  def submit(_event, %{assigns: %{modal: :new_room}} = term), do: NewRoom.submit(term)

  def submit(_event, %{assigns: %{modal: :settings}} = term), do: {:noreply, term}
  def submit(_event, %{assigns: %{modal: :workspace}} = term), do: {:noreply, term}

  def submit(_event, %{assigns: %{modal: :cancel}} = term), do: Cancellation.submit(term)

  def submit(_event, %{assigns: %{modal: :squad_dashboard}} = term), do: {:noreply, term}

  def submit(_event, %{assigns: %{modal: :directive}} = term), do: Directive.submit(term)

  def submit(_event, %{assigns: %{modal: :gate_review}} = term), do: GateReview.submit(term)

  def submit(_event, %{assigns: %{modal: :slash}} = term), do: execute_palette_command(term)

  def submit(_event, %{assigns: %{modal: nil}} = term) do
    draft = Map.get(term.assigns.drafts, term.assigns.selected_room_id, "")
    command = String.trim(draft)

    if String.starts_with?(command, "/") do
      case SlashPalette.command(command) do
        nil ->
          {:noreply, assign(term, notice: "Unknown command. Type / to see available commands.")}

        entry ->
          term |> SlashPalette.clear_draft() |> run_palette_action(entry.action)
      end
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
  def handle_event("prompt_changed", %{value: value}, %{assigns: %{modal: nil}} = term) do
    if String.starts_with?(value, "/") do
      {:noreply, SlashPalette.start(term, value)}
    else
      {:noreply, State.assign_draft(term, value)}
    end
  end

  def handle_event("prompt_changed", %{value: value}, %{assigns: %{modal: :slash}} = term) do
    {:noreply, SlashPalette.set_query(term, value)}
  end

  def handle_event("prompt_changed", %{value: value}, term) do
    {:noreply, State.assign_draft(term, value)}
  end

  def handle_event("new_room_changed", %{value: value}, term) do
    {:noreply, NewRoom.change(term, value)}
  end

  def handle_event("new_room_submitted", %{value: value}, term) do
    NewRoom.submit_value(term, value)
  end

  def handle_event("directive_changed", %{value: value}, term) do
    {:noreply, Directive.change(term, value)}
  end

  def handle_event("directive_submitted", %{value: value}, term) do
    Directive.submit_value(term, value)
  end

  def handle_event("prompt_submitted", %{value: value}, term) do
    term
    |> State.assign_draft(value)
    |> then(&submit(nil, &1))
  end

  def handle_event(
        :input,
        %{"key" => key},
        %{assigns: %{modal: :settings}} = term
      )
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, Settings.move(term, offset)}
  end

  def handle_event(:input, %{"key" => "Enter"}, %{assigns: %{modal: :settings}} = term) do
    {:noreply, Settings.confirm(term)}
  end

  def handle_event(
        :input,
        %{"key" => key},
        %{assigns: %{modal: :settings, settings: %{step: :providers}}} = term
      )
      when key in ["r", "R"] do
    {:noreply, Settings.refresh(term)}
  end

  def handle_event(
        :input,
        %{"key" => "Backspace"},
        %{assigns: %{modal: :settings, settings: %{step: :models}}} = term
      ) do
    {:noreply, Settings.backspace_query(term)}
  end

  def handle_event(
        :input,
        %{"key" => "Escape"},
        %{assigns: %{modal: :settings}} = term
      ) do
    {:noreply, Settings.back(term)}
  end

  def handle_event(
        :input,
        %{"key" => key},
        %{assigns: %{modal: :settings, settings: %{step: :models}}} = term
      ) do
    {:noreply, Settings.append_query(term, key)}
  end

  def handle_event(
        :input,
        %{"key" => key},
        %{assigns: %{modal: :slash}} = term
      )
      when key in ["ArrowUp", "ArrowDown"] do
    offset = if key == "ArrowUp", do: -1, else: 1
    {:noreply, SlashPalette.move(term, offset)}
  end

  def handle_event(:input, %{"key" => "Enter"}, %{assigns: %{modal: :slash}} = term) do
    execute_palette_command(term)
  end

  def handle_event(
        :input,
        %{"key" => "Backspace"},
        %{assigns: %{modal: :slash, slash: slash}} = term
      ) do
    query = String.slice(slash.query, 0, max(String.length(slash.query) - 1, 0))
    term = SlashPalette.set_query(term, query)

    if query == "" do
      {:noreply, SlashPalette.close(term)}
    else
      {:noreply, term}
    end
  end

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{modal: :slash}} = term) do
    {:noreply, SlashPalette.cancel(term)}
  end

  def handle_event(
        :input,
        %{"key" => key},
        %{assigns: %{modal: :slash}} = term
      ) do
    if String.length(key) == 1 and key >= " " do
      {:noreply, SlashPalette.set_query(term, term.assigns.slash.query <> key)}
    else
      {:noreply, term}
    end
  end

  def handle_event(:input, %{"key" => "Enter"}, %{focused: "new-room-name"} = term) do
    submit(nil, term)
  end

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{modal: :new_room}} = term) do
    {:noreply, NewRoom.cancel(term)}
  end

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{modal: :workspace}} = term) do
    {:noreply, Workspace.close(term)}
  end

  def handle_event(:input, %{"key" => "Enter"}, %{assigns: %{modal: :cancel}} = term) do
    submit(nil, term)
  end

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{modal: :cancel}} = term) do
    {:noreply, Cancellation.cancel(term)}
  end

  def handle_event(
        :input,
        %{"key" => "Escape"},
        %{assigns: %{modal: :squad_dashboard}} = term
      ) do
    {:noreply, SquadStatus.close(term)}
  end

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{modal: :directive}} = term) do
    {:noreply, Directive.cancel(term)}
  end

  def handle_event(
        :input,
        %{"key" => key},
        %{assigns: %{modal: :gate_review}} = term
      )
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, GateReview.move(term, offset)}
  end

  def handle_event(:input, %{"key" => key}, %{assigns: %{modal: :gate_review}} = term)
      when key in ["a", "A", "r", "R", "b", "B"] do
    GateReview.choose(term, key)
  end

  def handle_event(:input, %{"key" => "Enter"}, %{assigns: %{modal: :gate_review}} = term) do
    submit(nil, term)
  end

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{modal: :gate_review}} = term) do
    {:noreply, GateReview.cancel(term)}
  end

  def handle_event(:input, %{"key" => key}, %{focused: "rooms"} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, State.select_adjacent_room(term, offset)}
  end

  def handle_event(:input, %{"key" => "Enter"}, %{focused: "prompt"} = term) do
    submit(nil, term)
  end

  def handle_event(_, _, term), do: {:noreply, term}

  @impl true
  def handle_info({:projection_snapshot, projection}, term) do
    {:noreply, State.projection_updated(term, projection)}
  end

  def handle_info({:provider_catalog_updated, providers}, term) do
    {:noreply, State.providers_updated(term, providers)}
  end

  defp execute_palette_command(%{assigns: %{slash: slash}} = term) do
    term = SlashPalette.clear_draft(term)

    case Enum.at(SlashPalette.matches(slash.query), slash.index) do
      nil -> {:noreply, SlashPalette.close(term, "Unknown command: #{slash.query}")}
      match -> run_palette_action(term, match.action)
    end
  end

  defp run_palette_action(term, :new_room),
    do: {:noreply, term |> NewRoom.open() |> SlashPalette.clear()}

  defp run_palette_action(term, :cancel), do: {:noreply, Cancellation.open(term)}

  defp run_palette_action(term, :directive), do: {:noreply, Directive.open(term)}

  defp run_palette_action(term, :next_room),
    do: {:noreply, term |> State.select_adjacent_room(1) |> SlashPalette.close()}

  defp run_palette_action(term, :cycle_mode),
    do: {:noreply, term |> SlashPalette.close() |> cycle_mode_state()}

  defp run_palette_action(term, :squad),
    do: {:noreply, term |> SlashPalette.close() |> assign(mode: :squad)}

  defp run_palette_action(term, :squad_status), do: {:noreply, SquadStatus.open(term)}

  defp run_palette_action(term, :workspace),
    do: {:noreply, Workspace.open(term)}

  defp run_palette_action(term, :settings) do
    {:noreply, term |> Settings.open() |> SlashPalette.clear()}
  end

  defp run_palette_action(term, :theme),
    do: __MODULE__.cycle_theme(nil, SlashPalette.close(term))

  defp run_palette_action(term, :quit), do: quit(nil, SlashPalette.clear(term))

  defp run_palette_action(term, :gate_review), do: {:noreply, GateReview.open(term)}
end
