defmodule ReyCode.TUI.Activity do
  @moduledoc """
  Pure Projection-to-view presenter for truthful selected-session activity.

  It derives bounded labels and state from durable records. Animation frame
  advancement is deliberately outside this module and outside the Projection.
  """

  alias ReyCode.Orchestration.{Projection, ToolRun}
  alias ReyCode.Provider.Presentation
  alias ReyCode.Theme

  @max_invocation_rows_count 256
  @default_target_graphemes 48

  defmodule Item do
    @moduledoc false

    @enforce_keys [:id, :kind, :state, :label, :active?, :priority]
    defstruct [
      :id,
      :kind,
      :state,
      :label,
      :target,
      :elapsed_seconds,
      :outcome,
      :active?,
      :priority
    ]

    @type state :: :active | :blocked | :queued | :terminal | :idle
    @type t :: %__MODULE__{
            id: String.t(),
            kind: atom(),
            state: state(),
            label: String.t(),
            target: String.t() | nil,
            elapsed_seconds: non_neg_integer() | nil,
            outcome: atom() | nil,
            active?: boolean(),
            priority: non_neg_integer()
          }
  end

  defmodule TraceNote do
    @moduledoc false
    @enforce_keys [:text]
    defstruct [:text]

    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule TraceTool do
    @moduledoc false
    @enforce_keys [:item]
    defstruct [:item]

    @type t :: %__MODULE__{item: Item.t()}
  end

  defmodule View do
    @moduledoc false

    defstruct active?: false,
              header: nil,
              invocation_items: %{},
              ordered_invocation_ids: [],
              truncated?: false

    @type t :: %__MODULE__{
            active?: boolean(),
            header: Item.t() | nil,
            invocation_items: %{optional(String.t()) => Item.t()},
            ordered_invocation_ids: [String.t()],
            truncated?: boolean()
          }
  end

  @doc "Presents activity for exactly one selected Session's internal Session ID."
  @spec present(String.t() | nil, Projection.t(), map(), integer(), keyword()) :: View.t()
  def present(session_id, projection, providers, now_ms, opts \\ [])

  def present(nil, _projection, _providers, _now_ms, _opts), do: %View{}

  def present(session_id, projection, providers, now_ms, opts) do
    case Map.get(projection.sessions, session_id) do
      nil ->
        %View{}

      session ->
        target_graphemes = Keyword.get(opts, :target_graphemes, @default_target_graphemes)
        {visible_ids, truncated?} = selected_invocation_ids(session, projection)

        items =
          Map.new(visible_ids, fn invocation_id ->
            invocation = Map.fetch!(projection.invocations, invocation_id)
            turn = Map.fetch!(projection.turns, invocation.turn_id)

            {invocation_id,
             invocation_item(
               invocation,
               turn,
               session.workspace,
               projection,
               now_ms,
               target_graphemes
             )}
          end)

        header = header_item(session, projection, providers, items, now_ms, target_graphemes)

        %View{
          active?: Enum.any?(Map.values(items), & &1.active?) or active_item?(header),
          header: header,
          invocation_items: items,
          ordered_invocation_ids: visible_ids,
          truncated?: truncated?
        }
    end
  end

  @doc "Returns the presented item for one invocation, if retained in the bounded view."
  @spec invocation(View.t(), String.t() | nil) :: Item.t() | nil
  def invocation(%View{} = view, invocation_id), do: Map.get(view.invocation_items, invocation_id)

  @doc "Presents one ToolRun for timeline rendering through the same label contract."
  @spec tool(ToolRun.t() | map(), String.t(), integer(), keyword()) :: Item.t()
  def tool(run, workspace, now_ms, opts \\ []) do
    target_graphemes = Keyword.get(opts, :target_graphemes, @default_target_graphemes)
    tool_item(run, workspace, now_ms, target_graphemes)
  end

  @doc "Presents bounded native-provider tool lifecycle events as ordered activity rows."
  @spec provider_tools([map()], String.t(), integer(), keyword()) :: [Item.t()]
  def provider_tools(events, workspace, now_ms, opts \\ [])

  def provider_tools(events, workspace, now_ms, opts) when is_list(events) do
    target_graphemes = Keyword.get(opts, :target_graphemes, @default_target_graphemes)

    events
    |> provider_tool_rows()
    |> Enum.map(&provider_tool_item(&1, workspace, now_ms, target_graphemes))
  end

  def provider_tools(_events, _workspace, _now_ms, _opts), do: []

  @doc "Presents native-provider notes and collapsed tool lifecycles in frame order."
  @spec provider_trace([map()], String.t(), integer(), keyword()) ::
          [TraceNote.t() | TraceTool.t()]
  def provider_trace(events, workspace, now_ms, opts \\ [])

  def provider_trace(events, workspace, now_ms, opts) when is_list(events) do
    target_graphemes = Keyword.get(opts, :target_graphemes, @default_target_graphemes)

    notes =
      events
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.flat_map(fn {event, index} ->
        case provider_note_row(event, index) do
          nil -> []
          row -> [row]
        end
      end)

    tools =
      Enum.map(provider_tool_rows(events), fn row ->
        %{
          kind: :tool,
          item: provider_tool_item(row, workspace, now_ms, target_graphemes),
          sequence: row.first_sequence
        }
      end)

    (notes ++ tools)
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map(fn
      %{kind: :note, text: text} -> %TraceNote{text: text}
      %{kind: :tool, item: item} -> %TraceTool{item: item}
    end)
  end

  def provider_trace(_events, _workspace, _now_ms, _opts), do: []

  @doc "Whether any selected-session work is actively executing."
  @spec active?(View.t()) :: boolean()
  def active?(%View{active?: active?}), do: active?

  @doc "Renders one bounded status line using a caller-supplied shared animation frame."
  @spec text(Item.t() | nil, String.t()) :: String.t()
  def text(nil, _frame), do: ""

  def text(%Item{} = item, frame) do
    glyph = glyph(item, frame)

    [glyph, item.label, item.target, elapsed_label(item)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  @doc """
  Renders the ambient header status.

  Invocation targets repeat the owning Participant already named in the
  transcript. Other targets identify the file, command, or delegated work the
  operator needs to see in the persistent pulse.
  """
  @spec header_text(Item.t() | nil, String.t()) :: String.t()
  def header_text(nil, _frame), do: ""

  def header_text(%Item{kind: :invocation, label: "Thinking"} = item, frame),
    do: text(%{item | target: nil}, frame)

  def header_text(%Item{} = item, frame), do: text(item, frame)

  @doc "Returns a semantic color class suffix for an item."
  @spec color(Item.t() | nil) :: String.t()
  def color(%Item{state: :terminal, outcome: outcome}) when outcome in [:failed, :cancelled],
    do: "error"

  def color(%Item{state: :terminal, outcome: :completed}), do: "success"

  def color(%Item{state: :terminal, outcome: outcome}) when outcome in [:partial, :reworked],
    do: "warning"

  def color(%Item{state: :idle}), do: "muted"
  def color(%Item{state: :active}), do: "primary"
  def color(%Item{state: state}) when state in [:blocked, :queued], do: "warning"
  def color(_item), do: "muted"

  @doc "Returns the compact semantic badge used beside a message author."
  @spec badge(Item.t() | nil) :: String.t()
  def badge(%Item{state: :active}), do: "working"
  def badge(%Item{state: :blocked}), do: "paused"
  def badge(%Item{state: :queued}), do: "queued"
  def badge(%Item{state: :terminal, label: label}), do: String.downcase(label)
  def badge(_item), do: ""

  defp selected_invocation_ids(session, projection) do
    {ids, _seen, truncated?} =
      session.message_order
      |> Enum.reduce_while({[], MapSet.new(), false}, fn message_id, {ids, seen, _truncated?} ->
        invocation_id = invocation_id(projection, message_id)

        cond do
          is_nil(invocation_id) or MapSet.member?(seen, invocation_id) ->
            {:cont, {ids, seen, false}}

          MapSet.size(seen) >= @max_invocation_rows_count ->
            {:halt, {ids, seen, true}}

          true ->
            {:cont, {[invocation_id | ids], MapSet.put(seen, invocation_id), false}}
        end
      end)

    {ids, truncated?}
  end

  defp invocation_id(projection, message_id) do
    case Map.get(projection.messages, message_id) do
      %{invocation_id: invocation_id} -> invocation_id
      _message -> nil
    end
  end

  defp invocation_item(invocation, turn, workspace, projection, now_ms, target_graphemes) do
    status = Map.get(invocation, :status)
    active_tool = current_tool(invocation)

    cond do
      status == :awaiting_delegation ->
        delegation_item(invocation, projection, now_ms, target_graphemes)

      status == :waiting_tool_approval ->
        approval_item(invocation, workspace, now_ms, target_graphemes)

      status == :waiting_operator ->
        item(
          invocation.id,
          :question,
          :blocked,
          "Question",
          truncate(invocation.coordination.pending_question.question, target_graphemes),
          nil,
          nil,
          95
        )

      status == :running or not is_nil(active_tool) ->
        running_invocation_item(invocation, turn, workspace, now_ms, target_graphemes)

      status == :queued ->
        item(
          invocation.id,
          :invocation,
          :queued,
          "Queued",
          invocation.participant.name,
          nil,
          nil,
          20
        )

      status in [:completed, :failed, :cancelled] ->
        outcome = terminal_outcome(turn, invocation)
        terminal_item(invocation.id, :invocation, outcome)

      true ->
        item(invocation.id, :invocation, :idle, "Ready", nil, nil, nil, 0)
    end
  end

  defp running_invocation_item(invocation, turn, workspace, now_ms, target_graphemes) do
    case current_tool(invocation) do
      %{} = run when run.status == :running ->
        run
        |> tool_item(workspace, now_ms, target_graphemes)
        |> Map.put(:id, invocation.id)

      %{} = run when run.status == :awaiting_approval ->
        approval_tool_item(run, workspace, now_ms, target_graphemes)
        |> Map.put(:id, invocation.id)

      %{} = run when run.status in [:ready, :requested] ->
        run
        |> tool_item(workspace, now_ms, target_graphemes)
        |> Map.put(:id, invocation.id)

      _run ->
        provider_or_invocation_item(
          invocation,
          turn,
          workspace,
          now_ms,
          target_graphemes
        )
    end
  end

  defp provider_or_invocation_item(invocation, turn, workspace, now_ms, target_graphemes) do
    provider_tool =
      Map.get(invocation, :provider_activity_events, [])
      |> provider_tools(workspace, now_ms, target_graphemes: target_graphemes)
      |> Enum.reverse()
      |> Enum.find(& &1.active?)

    cond do
      provider_tool ->
        %{provider_tool | id: invocation.id}

      Map.get(invocation, :attempt, 1) > 1 ->
        item(
          invocation.id,
          :invocation,
          :active,
          "Retrying",
          "attempt #{invocation.attempt}",
          elapsed(turn, now_ms),
          nil,
          65
        )

      true ->
        item(
          invocation.id,
          :invocation,
          :active,
          "Thinking",
          invocation.participant.name,
          elapsed(turn, now_ms),
          nil,
          60
        )
    end
  end

  defp delegation_item(invocation, projection, now_ms, target_graphemes) do
    run =
      invocation.tool_run_order
      |> Enum.reverse()
      |> Enum.map(&run_for(invocation, &1))
      |> Enum.find(
        &match?(
          %{tool: tool, status: :running}
          when tool in ["spawn_task", :spawn_task, "spawn_tasks", :spawn_tasks],
          &1
        )
      )

    case run do
      nil ->
        item(invocation.id, :delegation, :blocked, "Paused", "delegation result", nil, nil, 55)

      run ->
        delegation_run_item(invocation, run, projection, now_ms, target_graphemes)
    end
  end

  defp delegation_run_item(invocation, run, projection, now_ms, target_graphemes) do
    child_ids = delegation_child_ids(run)
    children = Enum.map(child_ids, &Map.get(projection.invocations, &1))
    target = delegation_target(run, child_ids, target_graphemes)
    delegation_status_item(invocation, children, target, projection, now_ms)
  end

  defp delegation_child_ids(run) do
    case Map.get(run, :child_invocation_ids, []) do
      [] -> List.wrap(Map.get(run, :child_invocation_id))
      ids -> ids
    end
  end

  defp delegation_target(%{tool: tool}, child_ids, target_graphemes)
       when tool in ["spawn_tasks", :spawn_tasks],
       do: truncate("#{length(child_ids)} agents", target_graphemes)

  defp delegation_target(run, _child_ids, target_graphemes) do
    run.arguments
    |> argument("agent")
    |> then(&(&1 || "unknown agent"))
    |> single_line()
    |> truncate(target_graphemes)
  end

  defp delegation_status_item(invocation, children, target, projection, now_ms) do
    case Enum.find(children, &(&1 && &1.status == :running)) do
      nil ->
        delegation_idle_item(invocation, children, target)

      running ->
        started_at = child_started_at(running, projection)

        item(
          invocation.id,
          :delegation,
          :active,
          "Delegating",
          target,
          elapsed_from(started_at, now_ms),
          nil,
          75
        )
    end
  end

  defp delegation_idle_item(invocation, children, target) do
    if Enum.any?(children, &(&1 && &1.status == :queued)),
      do: item(invocation.id, :delegation, :queued, "Queued", target, nil, nil, 25),
      else: item(invocation.id, :delegation, :blocked, "Resuming", target, nil, nil, 55)
  end

  defp approval_item(invocation, workspace, now_ms, target_graphemes) do
    case current_tool(invocation) do
      %{} = run ->
        approval_tool_item(run, workspace, now_ms, target_graphemes)
        |> Map.put(:id, invocation.id)

      nil ->
        target = truncate("tool approval required · /tools", target_graphemes)
        item(invocation.id, :approval, :blocked, "Paused", target, nil, nil, 90)
    end
  end

  defp approval_tool_item(run, _workspace, _now_ms, target_graphemes) do
    tool = run.tool |> to_string() |> single_line()
    target = truncate("#{tool} approval required · /tools", target_graphemes)
    item(run.id, :approval, :blocked, "Paused", target, nil, nil, 90)
  end

  defp provider_tool_rows(events) do
    events
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce([], &fold_provider_tool_event/2)
    |> Enum.reverse()
  end

  defp provider_note_row(event, index) when is_map(event) do
    note = provider_value(event, "note")

    if provider_value(event, "kind") == "agent_note" and is_binary(note) and note != "" do
      %{kind: :note, text: note, sequence: provider_sequence(event, index)}
    end
  end

  defp provider_note_row(_event, _index), do: nil

  defp fold_provider_tool_event({event, index}, rows) do
    case provider_tool_row(event, index) do
      nil ->
        rows

      row ->
        {rows, matched?} = replace_running_provider_tool(rows, row)
        if matched?, do: rows, else: [row | rows]
    end
  end

  defp provider_tool_row(event, index) when is_map(event) do
    tool = provider_value(event, "tool")
    kind = provider_value(event, "kind")

    if is_binary(tool) and kind in ["tool_started", "tool_completed"] do
      state = provider_value(event, "state")
      call_id = provider_call_id(event, state)

      sequence = provider_sequence(event, index)

      %{
        id: call_id || "provider-tool:#{sequence}:#{tool}",
        call_id: call_id,
        tool: String.downcase(tool),
        status: provider_tool_status(kind, state),
        state: state,
        first_sequence: sequence
      }
    end
  end

  defp provider_tool_row(_event, _index), do: nil

  defp replace_running_provider_tool([], _row), do: {[], false}

  defp replace_running_provider_tool(rows, %{call_id: nil, status: :running}),
    do: {rows, false}

  defp replace_running_provider_tool(rows, %{call_id: nil} = row) do
    {rows, matched?} =
      rows
      |> Enum.reverse()
      |> replace_legacy_provider_tool(row)

    {Enum.reverse(rows), matched?}
  end

  defp replace_running_provider_tool(rows, row), do: replace_provider_tool_by_id(rows, row)

  defp replace_provider_tool_by_id([], _row), do: {[], false}

  defp replace_provider_tool_by_id([current | rest], row) do
    if current.status == :running and current.call_id == row.call_id do
      {[merge_provider_tool_row(current, row) | rest], true}
    else
      {rest, matched?} = replace_provider_tool_by_id(rest, row)
      {[current | rest], matched?}
    end
  end

  defp replace_legacy_provider_tool([], _row), do: {[], false}

  defp replace_legacy_provider_tool([current | rest], row) do
    if current.status == :running and current.tool == row.tool do
      {[merge_provider_tool_row(current, row) | rest], true}
    else
      {rest, matched?} = replace_legacy_provider_tool(rest, row)
      {[current | rest], matched?}
    end
  end

  defp merge_provider_tool_row(current, row) do
    %{
      row
      | id: current.id,
        state: merge_provider_state(current.state, row.state),
        first_sequence: current.first_sequence
    }
  end

  defp merge_provider_state(left, right) when is_map(left) and is_map(right),
    do: Map.merge(left, right)

  defp merge_provider_state(_left, right), do: right

  defp provider_tool_status("tool_started", _state), do: :running

  defp provider_tool_status("tool_completed", state) do
    status = provider_value(state, "status")

    if provider_value(state, "is_error") == true or status in ["failed", "error"],
      do: :failed,
      else: :completed
  end

  defp provider_call_id(event, state) do
    provider_value(event, "tool_call_id") || provider_value(state, "tool_call_id")
  end

  defp provider_sequence(event, fallback) do
    case provider_value(event, "frame_sequence") do
      sequence when is_integer(sequence) and sequence >= 0 -> sequence
      _sequence -> fallback
    end
  end

  defp provider_tool_item(row, workspace, now_ms, target_graphemes) do
    state = if is_map(row.state), do: row.state, else: %{}

    run = %{
      id: row.id,
      tool: row.tool,
      arguments: provider_tool_arguments(row.tool, state),
      status: row.status,
      result: provider_value(state, "result"),
      error: if(row.status == :failed, do: state, else: nil),
      requested_at: nil,
      started_at: nil,
      completed_at: nil
    }

    tool_item(run, workspace, now_ms, target_graphemes)
  end

  defp provider_tool_arguments(tool, state) do
    value =
      provider_value(state, "arguments") ||
        provider_value(state, "args") ||
        provider_value(state, "input")

    cond do
      is_map(value) -> value
      tool == "bash" and is_binary(value) -> %{"command" => value}
      true -> %{}
    end
  end

  defp provider_value(value, key) when is_map(value), do: Map.get(value, key)
  defp provider_value(_value, _key), do: nil

  defp tool_item(run, workspace, now_ms, target_graphemes) do
    name = to_string(run.tool)
    target = tool_target(name, run.arguments, workspace, target_graphemes)

    case run.status do
      :running ->
        item(
          run.id,
          :tool,
          :active,
          active_tool_label(name),
          target,
          elapsed(run, now_ms),
          nil,
          80
        )

      :awaiting_approval ->
        approval_tool_item(run, workspace, now_ms, target_graphemes)

      status when status in [:ready, :requested] ->
        item(run.id, :tool, :queued, "Queued", target || name, nil, nil, 20)

      status when status in [:completed, :failed, :denied, :interrupted] ->
        terminal_tool_item(run, name, target, target_graphemes)

      _status ->
        item(run.id, :tool, :idle, terminal_tool_label(name), target, nil, nil, 0)
    end
  end

  defp terminal_tool_item(%{status: :completed} = run, name, target, _target_graphemes) do
    item(run.id, :tool, :terminal, terminal_tool_label(name), target, nil, :completed, 10)
  end

  defp terminal_tool_item(%{status: :failed} = run, name, target, target_graphemes),
    do: terminal_tool_failure(run, name, target, "Failed", target_graphemes)

  defp terminal_tool_item(%{status: :denied} = run, name, target, target_graphemes),
    do: terminal_tool_failure(run, name, target, "Denied", target_graphemes)

  defp terminal_tool_item(%{status: :interrupted} = run, name, target, target_graphemes),
    do: terminal_tool_failure(run, name, target, "Interrupted", target_graphemes)

  defp terminal_tool_failure(run, name, target, label, target_graphemes) do
    failure_target =
      [humanize(name), target]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" · ")
      |> truncate(target_graphemes)

    item(run.id, :tool, :terminal, label, failure_target, nil, :failed, 10)
  end

  defp current_tool(invocation) do
    invocation.tool_run_order
    |> Enum.reverse()
    |> Enum.map(&run_for(invocation, &1))
    |> Enum.find(fn
      %{status: status} when status in [:running, :awaiting_approval, :ready, :requested] -> true
      _run -> false
    end)
  end

  defp run_for(invocation, run_id) do
    case Map.get(invocation.tool_runs, run_id) do
      nil -> nil
      run -> Map.put_new(run, :id, run_id)
    end
  end

  defp header_item(session, projection, providers, items, now_ms, target_graphemes) do
    cond do
      session.active_turn_id ->
        turn = Map.get(projection.turns, session.active_turn_id)
        active_turn_header(turn, items)

      session.queued_turn_ids != [] ->
        item("session:#{session.id}", :turn, :queued, "Queued", nil, nil, nil, 20)

      turn = recent_turn(session, projection) ->
        if turn.status == :terminal,
          do: terminal_item(turn.id, :turn, turn.outcome),
          else: provider_item(session, providers, now_ms, target_graphemes)

      true ->
        provider_item(session, providers, now_ms, target_graphemes)
    end
  end

  defp active_turn_header(nil, _items), do: nil

  defp active_turn_header(turn, items) when is_map(turn) do
    turn
    |> Map.get(:invocation_order, [])
    |> Enum.map(&Map.get(items, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index()
    |> Enum.max_by(fn {activity, index} -> {activity.priority, -index} end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp recent_turn(session, projection) do
    session.message_order
    |> Enum.find_value(fn message_id ->
      case Map.get(projection.messages, message_id) do
        %{turn_id: turn_id} when not is_nil(turn_id) -> Map.get(projection.turns, turn_id)
        _message -> nil
      end
    end)
  end

  defp provider_item(session, providers, _now_ms, target_graphemes) do
    primary = Enum.find(session.participants, &(&1.kind == :primary))
    provider = primary && Map.get(providers, primary.provider)

    cond do
      primary == nil ->
        item("session:#{session.id}", :provider, :blocked, "Model required", nil, nil, nil, 40)

      provider && provider.status == :checking ->
        target = primary.name |> single_line() |> truncate(target_graphemes)

        item(
          "session:#{session.id}",
          :provider,
          :active,
          "Checking provider",
          target,
          nil,
          nil,
          40
        )

      Presentation.ready?(provider, primary) ->
        item("session:#{session.id}", :provider, :idle, "Ready", nil, nil, nil, 0)

      true ->
        item(
          "session:#{session.id}",
          :provider,
          :blocked,
          "Provider unavailable",
          nil,
          nil,
          nil,
          40
        )
    end
  end

  defp terminal_outcome(_turn, invocation), do: Map.get(invocation, :status)

  defp terminal_item(id, kind, outcome) do
    item(id, kind, :terminal, outcome_label(outcome), nil, nil, outcome, 10)
  end

  defp active_tool_label("read"), do: "Reading"
  defp active_tool_label("grep"), do: "Searching"
  defp active_tool_label(name) when name in ["glob", "list"], do: "Scanning"
  defp active_tool_label("bash"), do: "Running"
  defp active_tool_label("edit"), do: "Editing"
  defp active_tool_label("write"), do: "Writing"
  defp active_tool_label("spawn_task"), do: "Delegating"
  defp active_tool_label("spawn_tasks"), do: "Delegating"
  defp active_tool_label("send_peer"), do: "Messaging"
  defp active_tool_label("process"), do: "Supervising"
  defp active_tool_label("memory"), do: "Recording"
  defp active_tool_label(_name), do: "Working"

  defp terminal_tool_label("read"), do: "Read"
  defp terminal_tool_label("grep"), do: "Searched"
  defp terminal_tool_label(name) when name in ["glob", "list"], do: "Scanned"
  defp terminal_tool_label("bash"), do: "Ran"
  defp terminal_tool_label("edit"), do: "Edited"
  defp terminal_tool_label("write"), do: "Wrote"
  defp terminal_tool_label("spawn_task"), do: "Delegated"
  defp terminal_tool_label("spawn_tasks"), do: "Delegated"
  defp terminal_tool_label("send_peer"), do: "Messaged"
  defp terminal_tool_label("process"), do: "Managed"
  defp terminal_tool_label("memory"), do: "Recorded"
  defp terminal_tool_label(name), do: humanize(name)

  defp tool_target(name, arguments, workspace, target_graphemes) do
    name
    |> raw_tool_target(arguments, workspace)
    |> single_line()
    |> truncate(target_graphemes)
    |> blank_to_nil()
  end

  defp raw_tool_target(name, arguments, workspace)
       when name in ["read", "edit", "write", "glob", "list"],
       do: path_target(argument(arguments, "path"), workspace)

  defp raw_tool_target("grep", arguments, _workspace), do: argument(arguments, "pattern")

  defp raw_tool_target("process", arguments, _workspace),
    do: argument(arguments, "name") || argument(arguments, "action")

  defp raw_tool_target("bash", arguments, _workspace), do: argument(arguments, "command")
  defp raw_tool_target("spawn_task", arguments, _workspace), do: argument(arguments, "agent")

  defp raw_tool_target("spawn_tasks", arguments, _workspace) do
    tasks = argument(arguments, "tasks") || []
    "#{length(tasks)} agents"
  end

  defp raw_tool_target("send_peer", arguments, _workspace), do: argument(arguments, "target")

  defp raw_tool_target("memory", arguments, _workspace),
    do:
      argument(arguments, "key") || argument(arguments, "query") || argument(arguments, "action")

  defp raw_tool_target(_name, arguments, _workspace), do: first_argument(arguments)

  defp path_target(nil, _workspace), do: nil

  defp path_target(path, workspace) when is_binary(path) do
    expanded =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, workspace)

    root = Path.expand(workspace)

    if root == "/" or expanded == root or String.starts_with?(expanded, root <> "/"),
      do: Path.relative_to(expanded, root),
      else: "<outside workspace>"
  end

  defp path_target(value, _workspace), do: value

  defp argument(arguments, key) when is_map(arguments), do: Map.get(arguments, key)
  defp argument(_arguments, _key), do: nil

  defp first_argument(arguments) when is_map(arguments) do
    case Enum.sort_by(arguments, fn {key, _value} -> to_string(key) end) do
      [{key, value} | _rest] -> "#{key}=#{value}"
      [] -> nil
    end
  end

  defp first_argument(_arguments), do: nil

  defp child_started_at(nil, _projection), do: nil

  defp child_started_at(child, projection) do
    case Map.get(projection.messages, child.message_id) do
      %{created_at: created_at} -> created_at
      _message -> nil
    end
  end

  defp elapsed(%{started_at: started_at, requested_at: requested_at}, now_ms),
    do: elapsed_from(started_at || requested_at, now_ms)

  defp elapsed(%{created_at: created_at}, now_ms), do: elapsed_from(created_at, now_ms)

  defp elapsed(_value, _now_ms), do: nil

  defp elapsed_from(nil, _now_ms), do: nil

  defp elapsed_from(%DateTime{} = datetime, now_ms),
    do: max(div(now_ms - DateTime.to_unix(datetime, :millisecond), 1_000), 0)

  defp elapsed_from(value, now_ms) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> elapsed_from(datetime, now_ms)
      _error -> nil
    end
  end

  defp elapsed_from(_value, _now_ms), do: nil

  defp outcome_label(:completed), do: "Completed"
  defp outcome_label(:partial), do: "Partial"
  defp outcome_label(:reworked), do: "Reworked"
  defp outcome_label(:failed), do: "Failed"
  defp outcome_label(:cancelled), do: "Cancelled"
  defp outcome_label(other), do: other |> to_string() |> humanize()

  defp glyph(%Item{state: :active}, frame), do: frame
  defp glyph(%Item{state: :blocked}, _frame), do: "Ⅱ"
  defp glyph(%Item{state: :queued}, _frame), do: "…"

  defp glyph(%Item{state: :terminal, outcome: outcome}, _frame),
    do: Theme.activity_outcome_glyph(outcome)

  defp glyph(%Item{state: :idle}, _frame), do: Theme.activity_idle_glyph()

  defp elapsed_label(%Item{elapsed_seconds: seconds}) when is_integer(seconds), do: "#{seconds}s"
  defp elapsed_label(_item), do: nil

  defp item(id, kind, state, label, target, elapsed_seconds, outcome, priority) do
    %Item{
      id: to_string(id),
      kind: kind,
      state: state,
      label: label,
      target: target,
      elapsed_seconds: elapsed_seconds,
      outcome: outcome,
      active?: state == :active,
      priority: priority
    }
  end

  defp active_item?(%Item{active?: active?}), do: active?
  defp active_item?(_item), do: false

  defp single_line(nil), do: nil

  defp single_line(value),
    do: value |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp truncate(nil, _limit), do: nil
  defp truncate(value, limit) when limit <= 0, do: String.slice(value, 0, 0)

  defp truncate(value, limit) do
    if String.length(value) <= limit, do: value, else: String.slice(value, 0, limit - 1) <> "…"
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()
end
