defmodule ReyCode.TUI do
  @moduledoc """
  The terminal-native coding session client.

  Owns global navigation, application lifecycle, and the composer. Each open
  modal delegates input, submission, focus, and rendering to its feature
  module through `ReyCode.TUI.Components.Modals`.
  """

  use Breeze.View

  alias ReyCode.Orchestration.Engine

  alias ReyCode.TUI.Components.Modals

  alias ReyCode.TUI.Mentions

  alias ReyCode.TUI.{Render, Settings, SlashPalette, State}

  # Mentions lives in lib/rey_code/tui/mentions.ex, which the parallel
  # compiler may not have finished when this view is compiled. Resolution
  # is a runtime call, so the undefined-module warning is a false positive.
  @compile {:no_warn_undefined, ReyCode.TUI.Mentions}

  @shutdown_timeout_ms 5_000

  @doc "Global keybindings shared by the application and tests."
  def global_keybindings do
    [
      {"Tab", "Move focus", &switch_focus/2},
      {"^N", "New session", &new_session/2},
      {"^P", "Commands", &open_command_palette/2},
      {"^S", "Send", &submit/2},
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

  def switch_focus(_event, %{assigns: %{home: true}} = term),
    do: {:noreply, focus(term, "prompt")}

  def switch_focus(_event, term) do
    next =
      if term.focused == "prompt",
        do: State.timeline_id(term.assigns.selected_room_id),
        else: "prompt"

    {:noreply, focus(term, next)}
  end

  def open_provider_settings(_event, %{assigns: %{modal: modal}} = term)
      when not is_nil(modal),
      do: {:noreply, term}

  def open_provider_settings(_event, term) do
    {:noreply, Settings.open(term)}
  end

  def new_session(_event, %{assigns: %{modal: modal}} = term) when not is_nil(modal),
    do: {:noreply, term}

  def new_session(_event, term), do: {:noreply, State.start_session(term)}

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

    cond do
      String.starts_with?(command, "/") ->
        SlashPalette.run_typed(term, command)

      String.starts_with?(command, "!") ->
        run_owner_command(term, String.trim_leading(command, "!"))

      true ->
        post_message(term, draft)
    end
  end

  def quit(_event, term) do
    server = self()

    Task.start(fn ->
      ref = Process.monitor(server)

      receive do
        {:DOWN, ^ref, :process, ^server, _reason} -> System.stop(0)
      after
        @shutdown_timeout_ms -> System.stop(1)
      end
    end)

    {:stop, State.stop_animation(term)}
  end

  defp post_message(term, draft) do
    if String.trim(draft) == "" do
      {:noreply, assign(term, notice: "Write a message first")}
    else
      case expand_mentions(term, draft) do
        {:ok, expanded, session_term} -> send_message(session_term, expanded)
        {:error, notice} -> {:noreply, assign(term, notice: notice)}
      end
    end
  end

  defp expand_mentions(term, draft) do
    workspace = term.assigns.projection.rooms[term.assigns.selected_room_id].workspace

    case Mentions.expand(draft, workspace, max_bytes: term.assigns.config.tools.read.max_bytes) do
      {:ok, expanded, _paths} ->
        case State.ensure_session(term, expanded) do
          {:ok, session_term} -> {:ok, expanded, session_term}
          {:error, reason} -> {:error, "Could not start session: #{reason}"}
        end

      {:error, {token, reason}} ->
        {:error, mention_notice(token, reason)}
    end
  end

  defp mention_notice(token, :file_not_found), do: "Cannot attach #{token}: file not found"
  defp mention_notice(token, :outside_workspace), do: "Cannot attach #{token}: outside workspace"
  defp mention_notice(token, :file_too_large), do: "Cannot attach #{token}: file too large"

  defp mention_notice(token, :total_too_large),
    do: "Cannot attach #{token}: attachments too large"

  defp mention_notice(token, _reason), do: "Cannot attach #{token}: unreadable"

  defp send_message(term, draft) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]
    follow_up? = room.active_turn_id != nil or room.queued_turn_ids != []

    case Engine.post_message(
           term.assigns.selected_room_id,
           draft,
           :direct,
           term.assigns.engine
         ) do
      {:ok, _turn_id} ->
        drafts = Map.put(term.assigns.drafts, term.assigns.selected_room_id, "")
        notice = if follow_up?, do: "Follow-up queued", else: nil
        {:noreply, assign(term, drafts: drafts, notice: notice, home: false)}

      {:error, {:participants_unconfigured, _participant_ids}} ->
        {:noreply, assign(term, notice: "Configure the Assistant model with /agents")}

      {:error, reason} ->
        {:noreply, assign(term, notice: "Could not send: #{reason}")}
    end
  end

  defp run_owner_command(term, raw_command) do
    command = String.trim(raw_command)

    if command == "" do
      {:noreply, assign(term, notice: "Type a command after !")}
    else
      with {:ok, session_term} <- State.ensure_session(term, command),
           :ok <-
             Engine.run_owner_command(
               session_term.assigns.selected_room_id,
               command,
               session_term.assigns.engine
             ) do
        drafts = Map.put(session_term.assigns.drafts, session_term.assigns.selected_room_id, "")
        {:noreply, assign(session_term, drafts: drafts, notice: nil, home: false)}
      else
        {:error, reason} ->
          {:noreply, assign(term, notice: "Could not run command: #{reason}")}
      end
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

  defp do_handle_event(:input, %{"key" => "Enter"}, %{focused: "prompt"} = term) do
    submit(nil, term)
  end

  defp do_handle_event(:input, %{"key" => "Escape"}, term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]

    if room && room.active_turn_id do
      case Engine.cancel_turn(room.active_turn_id, "Cancelled by user", term.assigns.engine) do
        :ok -> {:noreply, assign(term, notice: "Task cancelled")}
        {:error, _reason} -> {:noreply, term}
      end
    else
      {:noreply, term}
    end
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

  def handle_info({:activity_tick, token}, term) do
    case State.animation_tick(term, token) do
      {:ok, next} -> {:noreply, next}
      :stale -> {:noreply, term}
    end
  end

  @doc false
  def handle_info({:activity_tick, token, now_ms}, term) do
    case State.animation_tick(term, token, now_ms) do
      {:ok, next} -> {:noreply, next}
      :stale -> {:noreply, term}
    end
  end
end
