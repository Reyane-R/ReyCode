defmodule ReyCode.TUI.SlashPalette do
  @moduledoc "Command-palette data and state transitions for the terminal UI."

  alias Breeze.{Component, View}

  @commands [
    %{command: "/agents", description: "Configure room agents", action: :settings},
    %{command: "/cancel", description: "Cancel the running turn", action: :cancel},
    %{command: "/connect", description: "Connect a provider", action: :settings},
    %{command: "/direct", description: "Steer the running squad", action: :directive},
    %{command: "/mode", description: "Change orchestration mode", action: :cycle_mode},
    %{command: "/models", description: "Choose a model", action: :settings},
    %{command: "/new", description: "Create a project room", action: :new_room},
    %{command: "/quit", description: "Quit ReyCode", action: :quit},
    %{command: "/release", description: "Review the release gate", action: :gate_review},
    %{command: "/room", description: "Switch to the next room", action: :next_room},
    %{command: "/squad", description: "Select the leader-supervised squad", action: :squad},
    %{command: "/status", description: "Open the squad status dashboard", action: :squad_status},
    %{command: "/theme", description: "Change theme", action: :theme},
    %{command: "/tools", description: "Review a pending tool request", action: :tool_review},
    %{command: "/workspace", description: "Show the full workspace path", action: :workspace}
  ]

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

  @doc "Returns commands whose names begin with the query."
  @spec matches(String.t()) :: [map()]
  def matches(query), do: Enum.filter(@commands, &String.starts_with?(&1.command, query))

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
  @spec style(boolean(), pos_integer(), pos_integer(), map() | nil) :: map()
  def style(show_sidebar?, terminal_width, terminal_height, slash) do
    left = if show_sidebar?, do: 30, else: 0

    %{
      position: :fixed,
      left: left,
      bottom: 7,
      width: max(terminal_width - left, 1),
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

  @doc "Updates the command query and current room draft."
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

  @doc "Clears the current room draft."
  @spec clear_draft(map()) :: map()
  def clear_draft(term) do
    drafts = Map.put(term.assigns.drafts, term.assigns.selected_room_id, "")
    Component.assign(term, drafts: drafts)
  end

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
