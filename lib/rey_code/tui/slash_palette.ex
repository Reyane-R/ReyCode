defmodule ReyCode.TUI.SlashPalette do
  @moduledoc """
  Command-palette data, state transitions, and command execution for the
  terminal UI.
  """

  alias Breeze.{Component, View}
  alias ReyCode.Capabilities
  alias ReyCode.TUI.State

  alias ReyCode.TUI.{
    AgentProfile,
    Cancellation,
    Delegation,
    Help,
    ModelPicker,
    SessionPicker,
    Settings,
    ToolReview,
    Workspace
  }

  @commands Capabilities.commands()

  @doc "Completes the palette query when Tab is pressed while it is open."
  @spec focus(map()) :: map()
  def focus(term), do: complete(term)

  @doc "Executes the highlighted palette command."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: execute_selected(term)

  @doc "Handles one key press while the palette is open."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown"] do
    offset = if key == "ArrowUp", do: -1, else: 1
    {:noreply, move(term, offset)}
  end

  def handle_input("Enter", term), do: execute_selected(term)

  def handle_input("Backspace", %{assigns: %{slash: slash}} = term) do
    query = String.slice(slash.query, 0, max(String.length(slash.query) - 1, 0))
    term = set_query(term, query)

    if query == "" do
      {:noreply, close(term)}
    else
      {:noreply, term}
    end
  end

  def handle_input("Escape", term), do: {:noreply, cancel(term)}

  def handle_input(key, %{assigns: %{slash: slash}} = term) do
    if String.length(key) == 1 and key >= " " do
      {:noreply, set_query(term, slash.query <> key)}
    else
      {:noreply, term}
    end
  end

  @doc "Handles prompt changes while the palette owns the composer."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("prompt_changed", %{value: value}, term) do
    {:noreply, set_query(term, value)}
  end

  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns the complete command registry in display order."
  @spec commands() :: [map()]
  def commands, do: @commands

  @doc "Finds an exact command registry entry."
  @spec command(String.t()) :: map() | nil
  def command(name), do: Enum.find(@commands, &(&1.command == name))

  @doc "Opens the command palette while preserving the current draft."
  @spec open(map()) :: map()
  def open(term) do
    room_id = term.assigns.selected_room_id
    original_draft = Map.get(term.assigns.drafts, room_id, "")

    term
    |> Component.assign(
      drafts: Map.put(term.assigns.drafts, room_id, "/"),
      modal: :slash,
      slash: %{query: "/", index: 0, restore_draft: original_draft},
      notice: nil
    )
    |> View.focus("prompt")
  end

  @doc "Returns commands matching the query: exact, prefix, substring, then subsequence."
  @spec matches(String.t()) :: [map()]
  def matches(query) do
    query = String.downcase(query)

    @commands
    |> Enum.map(&{&1, fuzzy_rank(&1.command, query)})
    |> Enum.reject(fn {_command, rank} -> is_nil(rank) end)
    |> Enum.sort_by(fn {_command, rank} -> rank end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Starts slash completion for a slash-prefixed prompt value."
  @spec start(map(), String.t()) :: map()
  def start(term, value) do
    Component.assign(term,
      drafts: Map.put(term.assigns.drafts, term.assigns.selected_room_id, value),
      modal: :slash,
      slash: %{query: value, index: 0, restore_draft: nil}
    )
  end

  @doc "Returns the visible command rows around the current selection."
  @spec rows(map() | nil, pos_integer()) :: [{map(), non_neg_integer()}]
  def rows(nil, _terminal_height), do: []

  def rows(%{query: query, index: index}, terminal_height) do
    command_rows = matches(query) |> Enum.with_index()
    limit = row_limit(terminal_height)

    start =
      index |> Kernel.-(div(limit, 2)) |> max(0) |> min(max(length(command_rows) - limit, 0))

    Enum.slice(command_rows, start, limit)
  end

  @doc "Returns the fixed-position style for the command palette."
  @spec style(pos_integer(), pos_integer(), map() | nil) :: map()
  def style(terminal_width, terminal_height, slash) do
    %{
      position: :fixed,
      left: 0,
      bottom: 6,
      width: terminal_width,
      height: height(slash, terminal_height),
      layer: 40
    }
  end

  @doc "Returns the style class for a palette option row."
  def option_class(index, index), do: "inline w-full px-1 bg-primary text-bg"
  def option_class(_index, _selected), do: "inline w-full px-1 bg-panel"

  @doc "Returns the style class for a palette command name."
  def command_class(index, index), do: "w-14 text-bg"
  def command_class(_index, _selected), do: "w-14 text-warning"

  @doc "Returns the style class for a palette command description."
  def description_class(index, index), do: "text-bg"
  def description_class(_index, _selected), do: "text-muted"

  @doc "Moves the selected command by an offset, wrapping at either end."
  @spec move(map(), integer()) :: map()
  def move(%{assigns: %{slash: slash}} = term, offset) do
    count = length(matches(slash.query))

    if count == 0 do
      term
    else
      Component.assign(term, slash: %{slash | index: Integer.mod(slash.index + offset, count)})
    end
  end

  @doc "Completes the palette query with the first matching command."
  @spec complete(map()) :: map()
  def complete(%{assigns: %{slash: slash}} = term) do
    case matches(slash.query) do
      [first | _] -> set_query(term, first.command)
      [] -> term
    end
  end

  @doc "Updates the command query and current session draft."
  @spec set_query(map(), String.t()) :: map()
  def set_query(%{assigns: %{slash: slash}} = term, query) do
    Component.assign(term,
      drafts: Map.put(term.assigns.drafts, term.assigns.selected_room_id, query),
      slash: %{slash | query: query, index: 0}
    )
  end

  @doc "Closes the palette and focuses the prompt."
  @spec close(map(), String.t() | nil) :: map()
  def close(term, notice \\ nil) do
    term
    |> Component.assign(modal: nil, slash: nil, notice: notice)
    |> View.focus("prompt")
  end

  @doc "Cancels the palette and restores the draft that opened it."
  @spec cancel(map()) :: map()
  def cancel(%{assigns: %{slash: slash}} = term) do
    draft = if is_nil(slash.restore_draft), do: slash.query, else: slash.restore_draft

    term
    |> Component.assign(
      drafts: Map.put(term.assigns.drafts, term.assigns.selected_room_id, draft),
      modal: nil,
      slash: nil,
      notice: nil
    )
    |> View.focus("prompt")
  end

  @doc "Clears palette state without changing the active modal."
  @spec clear(map()) :: map()
  def clear(term), do: Component.assign(term, slash: nil)

  @doc "Clears the current session draft."
  @spec clear_draft(map()) :: map()
  def clear_draft(term) do
    drafts = Map.put(term.assigns.drafts, term.assigns.selected_room_id, "")
    Component.assign(term, drafts: drafts)
  end

  @doc """
  Runs a command typed exactly into the prompt, or flags it as unknown.
  """
  @spec run_typed(map(), String.t()) :: {:noreply, map()}
  def run_typed(term, command) do
    case command(command) do
      nil ->
        {:noreply,
         Component.assign(term, notice: "Unknown command. Type / to see available commands.")}

      entry ->
        term |> clear_draft() |> run_action(entry.action)
    end
  end

  @doc "Runs the currently highlighted palette match."
  @spec execute_selected(map()) :: {:noreply, map()}
  def execute_selected(%{assigns: %{slash: slash}} = term) do
    term = clear_draft(term)

    case Enum.at(matches(slash.query), slash.index) do
      nil -> {:noreply, close(term, "Unknown command: #{slash.query}")}
      match -> run_action(term, match.action)
    end
  end

  defp run_action(term, :new_session),
    do: {:noreply, term |> State.start_session() |> close()}

  defp run_action(term, :agent_profile), do: {:noreply, AgentProfile.open(term)}
  defp run_action(term, :delegation), do: {:noreply, Delegation.open(term)}
  defp run_action(term, :cancel), do: {:noreply, Cancellation.open(term)}

  defp run_action(term, :home),
    do: {:noreply, term |> close() |> Component.assign(home: true)}

  defp run_action(term, :workspace), do: {:noreply, Workspace.open(term)}

  defp run_action(term, :session_picker), do: {:noreply, SessionPicker.open(term)}
  defp run_action(term, :model_picker), do: {:noreply, ModelPicker.open(term)}
  defp run_action(term, :settings), do: {:noreply, term |> Settings.open() |> clear()}
  defp run_action(term, :theme), do: ReyCode.TUI.cycle_theme(nil, close(term))
  defp run_action(term, :quit), do: ReyCode.TUI.quit(nil, clear(term))
  defp run_action(term, :tool_review), do: {:noreply, ToolReview.open(term)}

  defp run_action(term, :help), do: {:noreply, term |> Help.open() |> clear()}

  defp fuzzy_rank(command, query) do
    cond do
      command == query -> 0
      String.starts_with?(command, query) -> 1
      String.contains?(command, query) -> 2
      subsequence?(String.graphemes(command), String.graphemes(query)) -> 3
      true -> nil
    end
  end

  defp subsequence?(_command, []), do: true
  defp subsequence?([], _query), do: false
  defp subsequence?([char | rest], [char | query]), do: subsequence?(rest, query)
  defp subsequence?([_other | rest], query), do: subsequence?(rest, query)

  defp height(nil, _terminal_height), do: 1

  defp height(%{query: query}, terminal_height) do
    query
    |> matches()
    |> length()
    |> min(row_limit(terminal_height))
    |> max(1)
  end

  defp row_limit(terminal_height), do: terminal_height |> Kernel.-(12) |> min(10) |> max(1)
end
