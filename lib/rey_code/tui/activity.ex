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

  @doc "Presents activity for exactly one selected Session's internal Room ID."
  @spec present(String.t() | nil, Projection.t(), map(), integer(), keyword()) :: View.t()
  def present(room_id, projection, providers, now_ms, opts \\ [])

  def present(nil, _projection, _providers, _now_ms, _opts), do: %View{}

  def present(room_id, projection, providers, now_ms, opts) do
    case Map.get(projection.rooms, room_id) do
      nil ->
        %View{}

      room ->
        target_graphemes = Keyword.get(opts, :target_graphemes, @default_target_graphemes)
        {visible_ids, truncated?} = selected_invocation_ids(room, projection)

        items =
          Map.new(visible_ids, fn invocation_id ->
            invocation = Map.fetch!(projection.invocations, invocation_id)
            turn = Map.fetch!(projection.turns, invocation.turn_id)

            {invocation_id,
             invocation_item(
               invocation,
               turn,
               room.workspace,
               projection,
               now_ms,
               target_graphemes
             )}
          end)

        header = header_item(room, projection, providers, items, now_ms, target_graphemes)

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

  @doc "Returns a semantic color class suffix for an item."
  @spec color(Item.t() | nil) :: String.t()
  def color(%Item{state: :terminal, outcome: outcome}) when outcome in [:failed, :cancelled],
    do: "error"

  def color(%Item{state: :terminal, outcome: :completed}), do: "success"

  def color(%Item{state: :terminal, outcome: outcome}) when outcome in [:partial, :reworked],
    do: "warning"

  def color(%Item{state: :idle}), do: "success"
  def color(%Item{state: state}) when state in [:active, :blocked, :queued], do: "warning"
  def color(_item), do: "muted"

  @doc "Returns the compact semantic badge used beside a message author."
  @spec badge(Item.t() | nil) :: String.t()
  def badge(%Item{state: :active}), do: "working"
  def badge(%Item{state: :blocked}), do: "paused"
  def badge(%Item{state: :queued}), do: "queued"
  def badge(%Item{state: :terminal, label: label}), do: String.downcase(label)
  def badge(_item), do: ""

  defp selected_invocation_ids(room, projection) do
    {ids, _seen, truncated?} =
      room.message_order
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
    attempt = Map.get(invocation, :attempt, 1)

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

      _run when attempt > 1 ->
        item(
          invocation.id,
          :invocation,
          :active,
          "Retrying",
          "attempt #{attempt}",
          elapsed(turn, now_ms),
          nil,
          65
        )

      _run ->
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
        &match?(%{tool: tool, status: :running} when tool in ["spawn_task", :spawn_task], &1)
      )

    if run do
      child = Map.get(projection.invocations, run.child_invocation_id)
      agent = argument(run.arguments, "agent") || "unknown agent"
      target = truncate(single_line(agent), target_graphemes)

      case child && child.status do
        :running ->
          started_at = child_started_at(child, projection)

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

        :queued ->
          item(invocation.id, :delegation, :queued, "Queued", target, nil, nil, 25)

        _status ->
          item(invocation.id, :delegation, :blocked, "Resuming", target, nil, nil, 55)
      end
    else
      item(invocation.id, :delegation, :blocked, "Paused", "delegation result", nil, nil, 55)
    end
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

  defp header_item(room, projection, providers, items, now_ms, target_graphemes) do
    cond do
      room.active_turn_id ->
        turn = Map.get(projection.turns, room.active_turn_id)
        active_turn_header(turn, items)

      room.queued_turn_ids != [] ->
        item("room:#{room.id}", :turn, :queued, "Queued", nil, nil, nil, 20)

      turn = recent_turn(room, projection) ->
        if turn.status == :terminal,
          do: terminal_item(turn.id, :turn, turn.outcome),
          else: provider_item(room, providers, now_ms, target_graphemes)

      true ->
        provider_item(room, providers, now_ms, target_graphemes)
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

  defp recent_turn(room, projection) do
    room.message_order
    |> Enum.find_value(fn message_id ->
      case Map.get(projection.messages, message_id) do
        %{turn_id: turn_id} when not is_nil(turn_id) -> Map.get(projection.turns, turn_id)
        _message -> nil
      end
    end)
  end

  defp provider_item(room, providers, _now_ms, target_graphemes) do
    primary = Enum.find(room.participants, &(&1.kind == :primary))
    provider = primary && Map.get(providers, primary.provider)

    cond do
      primary == nil ->
        item("room:#{room.id}", :provider, :blocked, "Model required", nil, nil, nil, 40)

      provider && provider.status == :checking ->
        target = primary.name |> single_line() |> truncate(target_graphemes)
        item("room:#{room.id}", :provider, :active, "Checking provider", target, nil, nil, 40)

      Presentation.ready?(provider, primary) ->
        item("room:#{room.id}", :provider, :idle, "Ready", nil, nil, nil, 0)

      true ->
        item("room:#{room.id}", :provider, :blocked, "Provider unavailable", nil, nil, nil, 40)
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
  defp active_tool_label(_name), do: "Working"

  defp terminal_tool_label("read"), do: "Read"
  defp terminal_tool_label("grep"), do: "Searched"
  defp terminal_tool_label(name) when name in ["glob", "list"], do: "Scanned"
  defp terminal_tool_label("bash"), do: "Ran"
  defp terminal_tool_label("edit"), do: "Edited"
  defp terminal_tool_label("write"), do: "Wrote"
  defp terminal_tool_label("spawn_task"), do: "Delegated"
  defp terminal_tool_label(name), do: humanize(name)

  defp tool_target(name, arguments, workspace, target_graphemes) do
    value =
      case name do
        name when name in ["read", "edit", "write", "glob", "list"] ->
          path_target(argument(arguments, "path"), workspace)

        "grep" ->
          argument(arguments, "pattern")

        "bash" ->
          argument(arguments, "command")

        "spawn_task" ->
          argument(arguments, "agent")

        _name ->
          first_argument(arguments)
      end

    value
    |> single_line()
    |> truncate(target_graphemes)
    |> blank_to_nil()
  end

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
