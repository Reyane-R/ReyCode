defmodule ReyCode.TUI.SlashPalette do
  @moduledoc """
  Command-palette data, state transitions, and command execution for the
  terminal UI.
  """

  alias Breeze.{Component, View}
  alias ReyCode.Capabilities
  alias ReyCode.Orchestration.Projection
  alias ReyCode.TUI.State

  alias ReyCode.TUI.{
    Advisor,
    AgentHub,
    AgentProfile,
    Artifacts,
    Cancellation,
    Completion,
    ContextBoundary,
    Delegation,
    Help,
    Hotkeys,
    ModelPicker,
    ModelTiers,
    OperatorQuestion,
    PromptHistory,
    Recovery,
    SessionCommand,
    SessionPicker,
    SessionTree,
    Settings,
    ToolInspector,
    ToolReview,
    WorkCommand,
    WorkPlan,
    Workspace
  }

  @commands Capabilities.commands()
  @commands_by_name Map.new(@commands, &{&1.command, &1})
  @default_command_names [
    "/task",
    "/agent",
    "/agents",
    "/model",
    "/connect",
    "/new",
    "/resume",
    "/plan",
    "/artifacts",
    "/help"
  ]
  @max_visible_row_count 12
  @reserved_composer_row_count 8
  @palette_border_row_count 1

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

  def handle_input(key, term) when key in ["BackTab", "Shift+Tab"],
    do: {:noreply, move(term, -1)}

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
  def handle_event("prompt_changed", %{value: value} = payload, term) do
    cursor = Map.get(payload, :cursor, Map.get(payload, "cursor", String.length(value)))
    {:noreply, set_query(term, value, cursor)}
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
    session_id = term.assigns.selected_session_id
    original_draft = Map.get(term.assigns.drafts, session_id, "")

    term
    |> Component.assign(
      drafts: Map.put(term.assigns.drafts, session_id, "/"),
      modal: :slash,
      slash: %{
        query: "/",
        cursor: 1,
        index: 0,
        accepted_id: nil,
        restore_draft: original_draft
      },
      notice: nil
    )
    |> View.focus("prompt")
  end

  @doc "Returns static command matches for capability and pure ranking tests."
  @spec matches(String.t()) :: [map()]
  def matches(query) do
    Completion.new(draft: query, commands: commands_for(%{}, query))
    |> Completion.candidates()
    |> Enum.map(& &1.payload)
  end

  @doc "Starts slash completion for a slash-prefixed prompt value."
  @spec start(map(), String.t()) :: map()
  def start(term, value) do
    Component.assign(term,
      drafts: Map.put(term.assigns.drafts, term.assigns.selected_session_id, value),
      modal: :slash,
      slash: %{
        query: value,
        cursor: String.length(value),
        index: 0,
        accepted_id: nil,
        restore_draft: nil
      }
    )
  end

  @doc "Returns visible contextual completion rows around the selection."
  @spec rows(map(), pos_integer()) :: [{Completion.Candidate.t(), non_neg_integer()}]
  def rows(%{slash: nil}, _terminal_height), do: []

  def rows(assigns, terminal_height) do
    completion_rows = assigns |> candidates() |> Enum.with_index()
    limit = row_limit(terminal_height)
    index = assigns.slash.index

    start =
      index
      |> Kernel.-(div(limit, 2))
      |> max(0)
      |> min(max(length(completion_rows) - limit, 0))

    Enum.slice(completion_rows, start, limit)
  end

  @doc "Returns the fixed-position style for the command palette."
  @spec style(pos_integer(), pos_integer(), map() | nil) :: map()
  def style(terminal_width, terminal_height, slash) do
    %{
      position: :fixed,
      left: 0,
      bottom: 6,
      height: height(slash, terminal_height) + @palette_border_row_count,
      width: terminal_width,
      layer: 40
    }
  end

  @doc "Returns the style class for a palette option row."
  def option_class(index, index), do: "inline w-full px-1 bg-primary text-bg"
  def option_class(_index, _selected), do: "inline w-full px-1 bg-panel"

  @doc "Returns the style class for a palette candidate label."
  def command_class(:command, index, index), do: "w-14 text-bg"
  def command_class(_kind, index, index), do: "pr-1 text-bg"
  def command_class(:command, _index, _selected), do: "w-14 text-warning"
  def command_class(_kind, _index, _selected), do: "pr-1 text-warning"

  @doc "Returns the style class for a palette command description."
  def description_class(index, index), do: "text-bg"
  def description_class(_index, _selected), do: "text-muted"

  @doc "Moves the selected candidate by an offset, wrapping at either end."
  @spec move(map(), integer()) :: map()
  def move(%{assigns: %{slash: slash}} = term, offset) do
    count = length(candidates(term.assigns))
    index = Completion.move(slash.index, count, offset)
    Component.assign(term, slash: %{slash | index: index})
  end

  @doc "Accepts the currently highlighted candidate without executing it."
  @spec complete(map()) :: map()
  def complete(%{assigns: %{slash: slash}} = term) do
    context = completion_context(term.assigns)

    case Enum.at(Completion.candidates(context), slash.index) do
      nil ->
        term

      candidate ->
        {:ok, query, cursor, accepted_id} = Completion.accept(context, candidate)
        set_query(term, query, cursor, accepted_id)
    end
  end

  @doc "Updates the command query and current session draft."
  @spec set_query(map(), String.t(), non_neg_integer() | nil, String.t() | nil) :: map()
  def set_query(term, query, cursor \\ nil, accepted_id \\ nil)

  def set_query(%{assigns: %{slash: slash}} = term, query, cursor, accepted_id) do
    Component.assign(term,
      drafts: Map.put(term.assigns.drafts, term.assigns.selected_session_id, query),
      slash: %{
        slash
        | query: query,
          cursor: cursor || String.length(query),
          index: 0,
          accepted_id: accepted_id
      }
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
      drafts: Map.put(term.assigns.drafts, term.assigns.selected_session_id, draft),
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
    drafts = Map.put(term.assigns.drafts, term.assigns.selected_session_id, "")
    Component.assign(term, drafts: drafts)
  end

  @doc "Parses, revalidates, and dispatches a typed command."
  @spec run_typed(map(), String.t()) :: {:noreply, map()}
  def run_typed(term, command) do
    context = completion_context(term.assigns, command, String.length(command))

    case Completion.parse(context) do
      {:ok, parsed} -> run_parsed(term, parsed)
      {:error, reason} -> {:noreply, Component.assign(term, notice: command_notice(reason))}
    end
  end

  @doc "Accepts and dispatches the currently highlighted candidate."
  @spec execute_selected(map()) :: {:noreply, map()}
  def execute_selected(%{assigns: %{slash: slash}} = term) do
    context = completion_context(term.assigns)

    case Enum.at(Completion.candidates(context), slash.index) do
      nil ->
        {:noreply, term |> clear_draft() |> close("Unknown command: #{slash.query}")}

      %{kind: :command, suffix: suffix} = candidate when suffix != "" ->
        if slash.query == candidate.insertion,
          do: accept_and_dispatch(term, context, candidate),
          else: accept_candidate(term, context, candidate)

      candidate ->
        accept_and_dispatch(term, context, candidate)
    end
  end

  defp accept_candidate(term, context, candidate) do
    {:ok, query, cursor, accepted_id} = Completion.accept(context, candidate)
    {:noreply, set_query(term, query, cursor, accepted_id)}
  end

  defp accept_and_dispatch(term, context, candidate) do
    {:ok, query, cursor, accepted_id} = Completion.accept(context, candidate)
    term = set_query(term, query, cursor, accepted_id)

    case Completion.parse(completion_context(term.assigns)) do
      {:ok, parsed} -> run_parsed(term, parsed)
      {:error, reason} -> {:noreply, Component.assign(term, notice: command_notice(reason))}
    end
  end

  defp run_parsed(term, %{command: command} = parsed)
       when command in ["/export", "/fork", "/rewind"] do
    term |> clear_draft() |> SessionCommand.run(command, parsed.argument)
  end

  defp run_parsed(term, %{command: command} = parsed)
       when command in ["/steer", "/dequeue"] do
    term |> clear_draft() |> WorkCommand.run(command, parsed.argument)
  end

  defp run_parsed(term, parsed) do
    term
    |> clear_draft()
    |> run_action(parsed.action, parsed.argument)
  end

  defp run_action(term, :new_session, nil),
    do: {:noreply, term |> State.start_session() |> close()}

  defp run_action(term, :agent_profile, nil), do: {:noreply, AgentProfile.open(term)}
  defp run_action(term, :delegation, nil), do: {:noreply, Delegation.open(term)}

  defp run_action(term, :delegation, participant_id),
    do: {:noreply, Delegation.open_for(term, participant_id)}

  defp run_action(term, :cancel, nil), do: {:noreply, Cancellation.open(term)}

  defp run_action(term, :home, nil),
    do: {:noreply, term |> close() |> Component.assign(home: true)}

  defp run_action(term, :workspace, nil), do: {:noreply, Workspace.open(term)}
  defp run_action(term, :workspace, path), do: {:noreply, Workspace.open(term, path)}

  defp run_action(term, :session_picker, nil), do: {:noreply, SessionPicker.open(term)}

  defp run_action(term, :session_picker, session_id) do
    next = term |> close() |> State.select_session(session_id) |> View.focus("prompt")
    {:noreply, next}
  end

  defp run_action(term, :model_picker, nil), do: {:noreply, ModelPicker.open(term)}

  defp run_action(term, :model_picker, %{provider: provider, model: model}),
    do: ModelPicker.select(term, provider, model)

  defp run_action(term, :settings, nil), do: {:noreply, term |> Settings.open() |> clear()}

  defp run_action(term, :settings, %{provider: provider, model: model}),
    do: {:noreply, Settings.open_at(term, provider, model)}

  defp run_action(term, :artifacts, nil), do: {:noreply, Artifacts.open(term)}
  defp run_action(term, :context_boundary, nil), do: {:noreply, ContextBoundary.open(term)}
  defp run_action(term, :hotkeys, nil), do: {:noreply, Hotkeys.open(term)}
  defp run_action(term, :prompt_history, nil), do: {:noreply, PromptHistory.open(term)}
  defp run_action(term, :retry, nil), do: Recovery.retry_latest(term)
  defp run_action(term, :session_tree, nil), do: {:noreply, SessionTree.open(term)}
  defp run_action(term, :tool_inspector, nil), do: {:noreply, ToolInspector.open(term)}

  defp run_action(term, :model_tiers, nil), do: {:noreply, ModelTiers.open(term)}
  defp run_action(term, :operator_question, nil), do: {:noreply, OperatorQuestion.open(term)}
  defp run_action(term, :work_plan, nil), do: {:noreply, WorkPlan.open(term)}

  defp run_action(term, :theme, nil), do: ReyCode.TUI.cycle_theme(nil, close(term))
  defp run_action(term, :quit, nil), do: ReyCode.TUI.quit(nil, clear(term))
  defp run_action(term, :tool_review, nil), do: {:noreply, ToolReview.open(term)}
  defp run_action(term, :help, nil), do: {:noreply, term |> Help.open() |> clear()}
  defp run_action(term, :agent_hub, nil), do: {:noreply, AgentHub.open(term)}
  defp run_action(term, :advisor, brief), do: Advisor.run(term, brief)

  defp candidates(assigns), do: assigns |> completion_context() |> Completion.candidates()

  defp completion_context(assigns, draft \\ nil, cursor \\ nil) do
    slash = Map.get(assigns, :slash)
    draft = draft || slash_query(slash)
    cursor = cursor || slash_cursor(slash, draft)
    {participants, workspace} = session_completion_context(assigns)
    sessions = completion_sessions(Map.get(assigns, :projection))

    Completion.new(
      draft: draft,
      cursor: cursor,
      commands: commands_for(assigns, draft),
      participants: participants,
      providers: Map.get(assigns, :providers, %{}),
      sessions: sessions,
      workspace: workspace
    )
  end

  defp commands_for(assigns, "/") do
    assigns
    |> contextual_command_names()
    |> Kernel.++(@default_command_names)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.map(fn {name, priority} ->
      @commands_by_name
      |> Map.fetch!(name)
      |> Map.put(:palette_priority, priority)
    end)
  end

  defp commands_for(_assigns, _draft), do: @commands

  defp contextual_command_names(%{projection: projection, selected_session_id: session_id}) do
    case Map.get(projection.sessions, session_id) do
      nil ->
        []

      session ->
        active_command_names(session) ++
          maybe_command(queued_follow_up?(projection, session), "/dequeue") ++
          maybe_command(Projection.delegated_invocations(projection, session_id) != [], "/hub") ++
          maybe_command(
            not is_nil(
              Recovery.latest_failed_turn(%{
                projection: projection,
                selected_session_id: session_id
              })
            ),
            "/retry"
          ) ++
          maybe_command(Map.get(session, :context_boundary_sequence, 0) > 0, "/context") ++
          maybe_command(
            ToolInspector.rows(%{projection: projection, selected_session_id: session_id}) != [],
            "/runs"
          )
    end
  end

  defp contextual_command_names(_assigns), do: []
  defp active_command_names(%{active_turn_id: nil}), do: []
  defp active_command_names(_session), do: ["/steer", "/cancel"]
  defp maybe_command(true, command), do: [command]
  defp maybe_command(false, _command), do: []

  defp queued_follow_up?(projection, session) do
    Enum.any?(session.queued_turn_ids, fn turn_id ->
      case Map.get(projection.turns, turn_id) do
        %{input_kind: :follow_up, status: :queued} -> true
        _other -> false
      end
    end)
  end

  defp slash_query(nil), do: ""
  defp slash_query(slash), do: slash.query
  defp slash_cursor(nil, draft), do: String.length(draft)
  defp slash_cursor(slash, draft), do: Map.get(slash, :cursor, String.length(draft))

  defp session_completion_context(%{projection: projection, selected_session_id: session_id}) do
    case Map.get(projection.sessions, session_id) do
      nil -> {[], nil}
      session -> {session.participants, session.workspace}
    end
  end

  defp session_completion_context(_assigns), do: {[], nil}
  defp completion_sessions(nil), do: []

  defp completion_sessions(projection) do
    projection.session_order
    |> Enum.reverse()
    |> Enum.map(&projection.sessions[&1])
  end

  defp command_notice(:unknown_command), do: "Unknown command. Type / to see available commands."
  defp command_notice(:missing_argument), do: "This command requires an argument"
  defp command_notice(:unexpected_argument), do: "This command accepts one argument"
  defp command_notice(:stale_argument), do: "The selected argument is no longer available"
  defp command_notice(:malformed_command), do: "Malformed command"
  defp command_notice(_reason), do: "Could not run command"

  defp height(nil, _terminal_height), do: 1
  defp height(%{slash: nil}, _terminal_height), do: 1

  defp height(%{slash: _slash} = assigns, terminal_height) do
    assigns
    |> candidates()
    |> length()
    |> min(row_limit(terminal_height))
    |> max(1)
  end

  defp height(%{query: query}, terminal_height) do
    query
    |> matches()
    |> length()
    |> min(row_limit(terminal_height))
    |> max(1)
  end

  defp row_limit(terminal_height) do
    terminal_height
    |> Kernel.-(@reserved_composer_row_count + @palette_border_row_count)
    |> min(@max_visible_row_count)
    |> max(1)
  end
end
