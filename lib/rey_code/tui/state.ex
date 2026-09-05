defmodule ReyCode.TUI.State do
  @moduledoc "Shared terminal state initialization and projection updates for the root view."

  alias Breeze.{Component, View}
  alias ReyCode.Memory.Store, as: MemoryStore
  alias ReyCode.Orchestration.{Engine, ModelTier}
  alias ReyCode.Provider.{Catalog, Presentation}
  alias ReyCode.RuntimeConfig
  alias ReyCode.Update

  alias ReyCode.TUI.{
    Activity,
    AgentProfile,
    AnimationClock,
    Artifacts,
    ContextBoundary,
    Decisions,
    Delegation,
    Hotkeys,
    MergeReview,
    ModelPicker,
    ModelTiers,
    Notice,
    OperatorQuestion,
    PromptHistory,
    SessionPicker,
    SessionTree,
    Settings,
    SlashPalette,
    Spinner,
    TimeAgo,
    ToolInspector,
    ToolReview
  }

  @max_trace_note_graphemes 240
  @max_trace_note_rows_count 100

  @doc "Subscribes the root view and initializes its stable assign shapes."
  @spec mount(keyword(), map()) :: {:ok, map()}
  def mount(opts, term) do
    engine = Keyword.get(opts, :engine, Engine)
    provider_catalog = Keyword.get(opts, :provider_catalog, Catalog)
    config = Keyword.get_lazy(opts, :config, &ReyCode.RuntimeConfig.fresh/0)
    memory_store = Keyword.get(opts, :memory_store, MemoryStore)
    workspace = Keyword.get_lazy(opts, :workspace, &File.cwd!/0)
    selected_session_id = ensure_workspace_session!(engine, workspace)
    projection = Engine.subscribe(engine)

    ReyCode.Herdr.report_projection(projection)
    catalog_snapshot = Catalog.subscribe(provider_catalog)
    keybindings = ReyCode.TUI.resolved_keybindings(config)

    maybe_check_updates(self(), config)

    now_ms = System.system_time(:millisecond)

    clock =
      AnimationClock.new(
        reduced_motion?: config.tui.reduced_motion?,
        schedule: Keyword.get(opts, :animation_schedule, &animation_schedule/2),
        cancel: Keyword.get(opts, :animation_cancel, &animation_cancel/1)
      )

    term =
      term
      |> View.focus("prompt")
      |> Component.assign(
        engine: engine,
        config: config,
        provider_catalog: provider_catalog,
        providers: catalog_snapshot.providers,
        providers_generation: catalog_snapshot.generation,
        memory_store: memory_store,
        projection: projection,
        selected_session_id: selected_session_id,
        drafts: %{},
        mode: :direct,
        home: true,
        modal: nil,
        cancel_turn_id: nil,
        context_boundary: ContextBoundary.initial(),
        artifacts: Artifacts.initial(),
        agent_profile: AgentProfile.initial(),
        delegation: Delegation.initial(),
        decisions: Decisions.initial(),
        hotkeys: Hotkeys.initial(),
        tool_review: ToolReview.initial(),
        operator_question: OperatorQuestion.initial(),
        prompt_history: PromptHistory.initial(),
        prompt_recall: PromptHistory.recall_initial(),
        work_plan_invocation_id: nil,
        merge_review: MergeReview.initial(),
        model_tiers: ModelTiers.initial(),
        session_tree: SessionTree.initial(),
        slash: nil,
        model_picker: ModelPicker.initial(),
        session_picker: SessionPicker.initial(),
        tool_inspector: ToolInspector.initial(),
        settings: Settings.initial(),
        workspace_preview_path: nil,
        animation_clock: clock,
        animation_now_ms: now_ms,
        animation_style: Keyword.get(opts, :animation_style, Spinner.style()),
        keybindings: keybindings,
        update_notice: nil,
        notice: nil
      )

    term = reconcile_animation(term, now_ms)

    if Settings.first_run_required?(projection, term.assigns.selected_session_id) do
      {:ok, Settings.open_first_run(term)}
    else
      {:ok, term}
    end
  end

  defp ensure_workspace_session!(engine, workspace) do
    case Engine.ensure_workspace_session(workspace, engine) do
      {:ok, session_id} ->
        session_id

      {:error, reason} ->
        raise ArgumentError, "cannot open Workspace #{inspect(workspace)}: #{reason}"
    end
  end

  @doc "Adds transient values consumed by the extracted renderer."
  @spec prepare_render(map()) :: map()
  def prepare_render(assigns) do
    width = assigns.breeze.terminal.width
    height = assigns.breeze.terminal.height
    session = assigns.projection.sessions[assigns.selected_session_id]
    message_width = message_width(width)
    target_graphemes = target_graphemes(width)

    activity =
      Activity.present(
        assigns.selected_session_id,
        assigns.projection,
        assigns.providers,
        assigns.animation_now_ms,
        target_graphemes: target_graphemes
      )

    frame =
      Spinner.glyph(
        AnimationClock.frame_index(assigns.animation_clock),
        assigns.config.tui.reduced_motion?,
        assigns.animation_style
      )

    budget = invocation_budget(session, assigns.projection)

    Component.assign(assigns,
      session: session,
      sessions: Enum.map(assigns.projection.session_order, &assigns.projection.sessions[&1]),
      messages:
        session_messages(
          session,
          assigns.projection,
          activity,
          assigns.animation_now_ms,
          target_graphemes
        ),
      activity: activity,
      activity_frame: frame,
      draft: Map.get(assigns.drafts, assigns.selected_session_id, ""),
      git_branch: git_branch(session && session.workspace),
      question_label: question_label(session, assigns.projection),
      token_label: token_label(session, assigns.projection, assigns.config, budget),
      token_label_class: token_label_class(budget),
      budget_notice: budget_notice(budget),
      composer_status: composer_status(session, assigns.providers),
      message_width: message_width,
      timeline_id: timeline_id(session.id),
      recent_session_rows: recent_session_rows(assigns),
      slash_rows: slash_rows(assigns, height),
      slash_style: SlashPalette.style(width, height, assigns),
      slash_empty_label: SlashPalette.empty_label(assigns),
      tool_review_options: ToolReview.options()
    )
  end

  defp recent_session_rows(assigns) do
    assigns.projection.session_order
    |> Enum.reverse()
    |> Enum.map(&assigns.projection.sessions[&1])
    |> Enum.filter(&(&1.message_order != []))
    |> Enum.take(3)
    |> Enum.map(fn session ->
      %{
        title: session.title,
        meta: TimeAgo.format(session.created_at) <> "  ·  " <> Path.basename(session.workspace)
      }
    end)
  end

  defp question_label(nil, _projection), do: ""

  defp question_label(session, projection) do
    count =
      projection.invocations
      |> Map.values()
      |> Enum.count(fn invocation ->
        coordination = Map.get(invocation, :coordination)

        Map.get(invocation, :session_id) == session.id and
          match?(%{pending_question: question} when not is_nil(question), coordination)
      end)

    case count do
      0 -> ""
      1 -> "1 question waiting"
      value -> "#{value} questions waiting"
    end
  end

  defp git_branch(nil), do: nil

  defp git_branch(workspace) do
    case File.read(Path.join(workspace, ".git/HEAD")) do
      {:ok, "ref: refs/heads/" <> branch} -> "⑂ " <> middle_truncate(String.trim(branch), 20)
      {:ok, _detached} -> "⑂ detached"
      _other -> nil
    end
  end

  defp middle_truncate(value, max_length) do
    if String.length(value) <= max_length do
      value
    else
      left_length = div(max_length - 3, 2)
      right_length = max_length - 3 - left_length

      String.slice(value, 0, left_length) <>
        "..." <> String.slice(value, -right_length, right_length)
    end
  end

  defp token_label(session, projection, config, nil) do
    tokens = token_usage(session, projection)

    "#{meter_bar(session, projection, config)}  tok #{format_tokens(tokens)}/#{format_tokens(config.orchestration.context_budget_tokens)}"
  end

  defp token_label(_session, _projection, _config, budget), do: invocation_budget_label(budget)

  defp invocation_budget(nil, _projection), do: nil

  defp invocation_budget(session, projection) do
    invocation =
      session.message_order
      |> Enum.map(&projection.messages[&1])
      |> Enum.filter(&(&1 && &1.invocation_id))
      |> Enum.map(&projection.invocations[&1.invocation_id])
      |> Enum.find(&(&1 && &1.status not in [:completed, :failed, :cancelled]))

    case invocation && Map.get(invocation, :execution_context) do
      %{token_budget_tokens: limit, model_tier: tier} ->
        used = ModelTier.used_tokens(invocation)

        %{
          participant: invocation.participant.name,
          tier: tier,
          used: used,
          limit: limit,
          ratio: if(is_number(used) and limit > 0, do: used / limit, else: nil)
        }

      _missing_budget ->
        nil
    end
  end

  defp invocation_budget_label(budget) do
    used = if is_number(budget.used), do: format_tokens(budget.used), else: "?"
    warning = if is_number(budget.ratio) and budget.ratio >= 0.8, do: "Ⅱ ", else: ""
    "#{warning}tok #{budget.tier} #{used}/#{format_tokens(budget.limit)}"
  end

  defp token_label_class(%{ratio: ratio}) when is_number(ratio) and ratio >= 0.8,
    do: "pl-2 text-warning"

  defp token_label_class(_budget), do: "pl-2 text-muted"

  defp budget_notice(%{ratio: ratio} = budget) when is_number(ratio) and ratio >= 0.8 do
    percent = round(ratio * 100)

    Notice.new(
      :warning,
      "#{budget.participant} has used #{percent}% of its #{budget.tier} token budget"
    )
  end

  defp budget_notice(_budget), do: nil

  @doc """
  Classifies composer readiness from the Primary Participant and catalog.

  The label states what the Assistant can do right now — never a generic
  input-ready "Ready" while no model can answer.
  """
  @spec composer_status(map(), map()) :: %{label: String.t(), class: String.t()}
  def composer_status(session, providers) do
    session
    |> primary_participant()
    |> status_for(providers)
  end

  defp status_for(nil, _providers), do: connect_status()

  defp status_for(primary, providers) do
    provider = Map.get(providers, primary.provider)

    cond do
      unconfigured?(primary) ->
        connect_status()

      provider && provider.status == :checking ->
        %{label: "Checking providers…", class: "text-muted"}

      Presentation.ready?(provider, primary) ->
        %{label: "Ready", class: "text-muted"}

      true ->
        %{label: "Provider unavailable — /connect", class: "text-warning"}
    end
  end

  defp primary_participant(nil), do: nil

  defp primary_participant(session),
    do: Enum.find(session.participants, &(&1.kind == :primary))

  defp unconfigured?(primary) do
    primary.provider == :unconfigured or is_nil(primary.model)
  end

  defp connect_status, do: %{label: "Connect a model — /connect", class: "text-warning"}

  defp meter_bar(session, projection, config) do
    used = token_usage(session, projection)
    budget = config.orchestration.context_budget_tokens
    ratio = if budget > 0, do: used / budget, else: 0.0
    cells = 5
    filled = round(ratio * cells) |> min(cells) |> max(0)
    String.duplicate("■", filled) <> String.duplicate("□", cells - filled)
  end

  defp token_usage(session, projection) do
    Enum.reduce(projection.invocations, 0, fn {_id, invocation}, acc ->
      if invocation.session_id == session.id,
        do: acc + usage_tokens(invocation.usage),
        else: acc
    end)
  end

  defp usage_tokens(nil), do: 0

  defp usage_tokens(usage) when is_map(usage) do
    tokens = usage_value(usage, :tokens)

    cond do
      is_number(usage_number(usage, :total_tokens)) -> usage_number(usage, :total_tokens)
      is_number(tokens) -> tokens
      is_map(tokens) -> nested_token_total(tokens)
      true -> split_token_total(usage)
    end
    |> trunc()
  end

  defp usage_tokens(_other), do: 0

  defp nested_token_total(tokens) do
    usage_number(tokens, :total) ||
      (usage_number(tokens, :input) || 0) + (usage_number(tokens, :output) || 0)
  end

  defp split_token_total(usage) do
    prompt = usage_number(usage, :prompt_tokens) || usage_number(usage, :input_tokens) || 0

    completion =
      usage_number(usage, :completion_tokens) || usage_number(usage, :output_tokens) || 0

    prompt + completion
  end

  defp usage_number(usage, key) do
    case usage_value(usage, key) do
      value when is_number(value) -> value
      _other -> nil
    end
  end

  defp usage_value(usage, key), do: Map.get(usage, key, Map.get(usage, Atom.to_string(key)))

  defp format_tokens(value) when value >= 1_000 do
    text = :erlang.float_to_binary(value / 1_000.0, [{:decimals, 1}])
    text = if String.ends_with?(text, ".0"), do: String.trim_trailing(text, ".0"), else: text
    text <> "k"
  end

  defp format_tokens(value), do: Integer.to_string(value)

  defp slash_rows(assigns, height) do
    rows =
      Enum.map(SlashPalette.rows(assigns, height), fn {candidate, index} ->
        %{
          command: candidate.label,
          description: candidate.detail,
          option_class: SlashPalette.option_class(index, assigns.slash.index),
          command_class: SlashPalette.command_class(candidate.kind, index, assigns.slash.index),
          description_class: SlashPalette.description_class(index, assigns.slash.index)
        }
      end)

    if rows == [] and not is_nil(assigns.slash) do
      [
        %{
          command: SlashPalette.empty_label(assigns),
          description: "",
          option_class: "inline w-full px-1 bg-panel",
          command_class: "pr-1 text-muted",
          description_class: "text-muted"
        }
      ]
    else
      rows
    end
  end

  @doc """
  Applies a projection broadcast unless it is older than the held one.

  Subscription registration and the snapshot reply are separate steps, so a
  broadcast dispatched in between can sit ahead of the baseline reply in the
  mailbox. Snapshots at or below the current `sequence` are ignored.
  """
  @spec projection_updated(map(), map()) :: map()
  def projection_updated(term, %{sequence: sequence} = projection) do
    term =
      if Map.has_key?(term.assigns, :projection) and
           sequence <= term.assigns.projection.sequence do
        term
      else
        selected_session_id =
          if Map.has_key?(projection.sessions, term.assigns.selected_session_id) do
            term.assigns.selected_session_id
          else
            List.last(projection.session_order)
          end

        Component.assign(term, projection: projection, selected_session_id: selected_session_id)
      end

    reconcile_animation(term)
  end

  @doc "Applies a catalog snapshot unless its generation is not newer."
  @spec providers_updated(map(), ReyCode.Provider.Catalog.Snapshot.t()) :: map()
  def providers_updated(term, %{generation: generation} = snapshot) do
    if generation <= term.assigns.providers_generation do
      term
    else
      refresh = Notice.new(:info, Presentation.refresh_notice())

      notice =
        if term.assigns.notice == refresh,
          do: nil,
          else: term.assigns.notice

      term =
        Component.assign(term,
          providers: snapshot.providers,
          providers_generation: generation,
          notice: notice
        )

      term = if term.assigns.modal == :settings, do: Settings.reconcile_options(term), else: term
      reconcile_animation(term)
    end
  end

  @doc "Reconciles the one animation timer with selected-session work."
  @spec reconcile_animation(map(), integer()) :: map()
  def reconcile_animation(term, now_ms \\ System.system_time(:millisecond)) do
    if Map.has_key?(term.assigns, :animation_clock) do
      activity = current_activity(term, now_ms)
      active? = not term.assigns.home and Activity.active?(activity)
      clock = AnimationClock.reconcile(term.assigns.animation_clock, active?)
      Component.assign(term, animation_clock: clock, animation_now_ms: now_ms)
    else
      term
    end
  end

  @doc "Applies one animation tick when its token is current."
  @spec animation_tick(map(), reference(), integer()) :: {:ok, map()} | :stale
  def animation_tick(term, token, now_ms \\ System.system_time(:millisecond)) do
    activity = current_activity(term, now_ms)
    active? = not term.assigns.home and Activity.active?(activity)

    case AnimationClock.tick(term.assigns.animation_clock, token, active?) do
      {:ok, clock} ->
        {:ok, Component.assign(term, animation_clock: clock, animation_now_ms: now_ms)}

      :stale ->
        :stale
    end
  end

  @doc "Selects one durable Session and reconciles local animation state."
  @spec select_session(map(), String.t(), boolean()) :: map()
  def select_session(term, session_id, home? \\ false) do
    term
    |> Component.assign(selected_session_id: session_id, home: home?)
    |> reconcile_animation()
  end

  @doc "Stops local animation before TUI teardown."
  @spec stop_animation(map()) :: map()
  def stop_animation(term) do
    clock = AnimationClock.stop(term.assigns.animation_clock)
    Component.assign(term, animation_clock: clock)
  end

  @doc "Updates the selected session's composer draft."
  @spec assign_draft(map(), String.t()) :: map()
  def assign_draft(term, value) do
    drafts = Map.put(term.assigns.drafts, term.assigns.selected_session_id, value)

    Component.assign(term,
      drafts: drafts,
      prompt_recall: PromptHistory.recall_initial()
    )
  end

  @doc "Creates and selects a fresh titled durable session for the session's first input."
  @spec ensure_session(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_session(%{assigns: %{home: true}} = term, first_input) do
    case Engine.create_session(
           term.assigns.selected_session_id,
           session_title(first_input),
           term.assigns.engine
         ) do
      {:ok, session_id} ->
        projection = Engine.snapshot(term.assigns.engine)
        drafts = Map.put(term.assigns.drafts, session_id, "")

        next =
          term
          |> Component.assign(
            projection: projection,
            drafts: drafts,
            notice: nil
          )
          |> select_session(session_id)

        {:ok, next}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ensure_session(term, _first_input), do: {:ok, term}

  defp session_title(text) do
    title =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.join(" ")

    if String.length(title) > 60,
      do: String.slice(title, 0, 60) <> "…",
      else: title
  end

  @doc "Returns to a clean session home without creating persistence yet."
  @spec start_session(map()) :: map()
  def start_session(term) do
    source_session_id = term.assigns.selected_session_id
    drafts = Map.put(term.assigns.drafts, source_session_id, "")

    term
    |> Component.assign(
      drafts: drafts,
      modal: nil,
      notice: nil
    )
    |> select_session(source_session_id, true)
  end

  @doc "Returns the selected session timeline element ID."
  @spec timeline_id(term()) :: String.t()
  def timeline_id(session_id), do: "timeline-#{session_id}"

  defp session_messages(nil, _projection, _activity, _now_ms, _target_graphemes), do: []

  defp session_messages(session, projection, activity, now_ms, target_graphemes) do
    messages =
      session.message_order
      |> Enum.reverse()
      |> Enum.map(fn message_id ->
        message = projection.messages[message_id]
        invocation = projection.invocations[message.invocation_id]

        {execution_rows, hidden_trace_note_count} =
          execution_rows(invocation, session.workspace, now_ms, target_graphemes)

        message
        |> Map.put(:kind, :message)
        |> Map.put(:invocation, invocation)
        |> Map.put(:activity, Activity.invocation(activity, message.invocation_id))
        |> Map.put(:execution_rows, execution_rows)
        |> Map.put(:hidden_trace_note_count, hidden_trace_note_count)
        |> Map.put(:turn, projection.turns[message.turn_id])
      end)

    append_context_boundary(messages, session)
  end

  defp append_context_boundary(messages, %{context_boundary_sequence: sequence} = session)
       when sequence > 0 do
    boundary = %{
      kind: :context_boundary,
      created_sequence: sequence,
      summary: session.context_summary || "Summary unavailable",
      compacted_at: session.context_compacted_at
    }

    {before, after_boundary} = Enum.split_while(messages, &(&1.created_sequence <= sequence))
    before ++ [boundary | after_boundary]
  end

  defp append_context_boundary(messages, _session), do: messages

  defp execution_rows(invocation, workspace, now_ms, target_graphemes) do
    {rows, hidden_note_row_count} =
      (provider_trace_rows(invocation, workspace, now_ms, target_graphemes) ++
         durable_tool_run_rows(invocation, workspace, now_ms, target_graphemes))
      |> bound_trace_notes()

    {rows, hidden_note_row_count + provider_activity_hidden_note_rows(invocation)}
  end

  # Compatibility: retired CLI activity is still rendered from durable history.
  defp provider_trace_rows(
         %{participant: %{provider: provider}} = invocation,
         workspace,
         now_ms,
         target_graphemes
       )
       when provider in [:omp, :opencode, "omp", "opencode"] do
    events = Map.get(invocation, :provider_activity_events, [])

    if is_list(events) and
         Enum.any?(events, &(Map.get(&1, "kind") in ["agent_note", "activity_overflow"])) do
      events
      |> Activity.provider_trace(workspace, now_ms, target_graphemes: target_graphemes)
      |> Enum.flat_map(&normalize_provider_trace_row/1)
    else
      legacy_provider_trace_rows(invocation, workspace, now_ms, target_graphemes)
    end
  end

  defp provider_trace_rows(_invocation, _workspace, _now_ms, _target_graphemes), do: []

  defp provider_activity_hidden_note_rows(invocation) when is_map(invocation) do
    invocation
    |> Map.get(:provider_activity_events, [])
    |> Enum.find_value(0, fn
      %{"kind" => "activity_overflow", "hidden_note_row_count" => count}
      when is_integer(count) and count >= 0 ->
        count

      _event ->
        nil
    end)
  end

  defp provider_activity_hidden_note_rows(_invocation), do: 0

  defp legacy_provider_trace_rows(invocation, workspace, now_ms, target_graphemes) do
    note_trace_rows(Map.get(invocation, :notes, [])) ++
      (invocation
       |> Map.get(:provider_activity_events, [])
       |> Activity.provider_tools(workspace, now_ms, target_graphemes: target_graphemes)
       |> Enum.map(&with_empty_diff/1))
  end

  defp normalize_provider_trace_row(%Activity.TraceNote{text: text}), do: note_trace_rows([text])
  defp normalize_provider_trace_row(%Activity.TraceTool{item: item}), do: [with_empty_diff(item)]

  defp note_trace_rows(notes) when is_list(notes) do
    notes
    |> Enum.flat_map(&note_lines/1)
    |> Enum.map(&%{kind: :note, text: &1})
  end

  defp note_trace_rows(_notes), do: []

  defp with_empty_diff(item) do
    item
    |> Map.put(:diff_lines, [])
    |> Map.put(:diff_truncated?, false)
  end

  defp durable_tool_run_rows(invocation, workspace, now_ms, target_graphemes)
       when is_map(invocation) do
    invocation.tool_run_order
    |> List.wrap()
    |> Enum.flat_map(fn run_id ->
      case Map.get(invocation.tool_runs || %{}, run_id) do
        nil ->
          []

        run ->
          run = Map.put_new(run, :id, run_id)
          item = Activity.tool(run, workspace, now_ms, target_graphemes: target_graphemes)
          preview = tool_diff_preview(run)

          [
            item
            |> Map.put(:diff_lines, preview["lines"])
            |> Map.put(:diff_truncated?, preview["truncated"])
          ]
      end
    end)
  end

  defp durable_tool_run_rows(_invocation, _workspace, _now_ms, _target_graphemes), do: []

  defp tool_diff_preview(%{result: %{"metadata" => %{"_tui_diff" => preview}}})
       when is_map(preview) do
    %{
      "lines" => Map.get(preview, "lines", []),
      "truncated" => !!Map.get(preview, "truncated")
    }
  end

  defp tool_diff_preview(_run), do: %{"lines" => [], "truncated" => false}

  defp bound_trace_notes(rows) do
    overflow =
      max(Enum.count(rows, &match?(%{kind: :note}, &1)) - @max_trace_note_rows_count, 0)

    {bounded, _remaining} =
      Enum.map_reduce(rows, overflow, fn
        %{kind: :note}, remaining when remaining > 0 -> {nil, remaining - 1}
        row, remaining -> {row, remaining}
      end)

    {Enum.reject(bounded, &is_nil/1), overflow}
  end

  defp note_lines(note) when is_binary(note) do
    note
    |> String.split(~r/\R+/, trim: true)
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_note()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp note_lines(_note), do: []

  defp truncate_note(note) do
    if String.length(note) <= @max_trace_note_graphemes,
      do: note,
      else: String.slice(note, 0, @max_trace_note_graphemes - 1) <> "…"
  end

  defp current_activity(term, now_ms) do
    Activity.present(
      term.assigns.selected_session_id,
      term.assigns.projection,
      term.assigns.providers,
      now_ms,
      target_graphemes: 48
    )
  end

  defp target_graphemes(width), do: width |> Kernel.-(34) |> max(16) |> min(72)

  defp animation_schedule(token, delay_ms),
    do: Process.send_after(self(), {:activity_tick, token}, delay_ms)

  @doc """
  Spawns the release-only update check; `auto?/1` is the injected release gate.
  """
  @spec maybe_check_updates(pid(), RuntimeConfig.t(), (RuntimeConfig.TUI.t() -> boolean())) ::
          :ok
  def maybe_check_updates(parent, config, auto? \\ &Update.auto_check?/1) do
    if auto?.(config.tui) do
      Task.start(fn -> Update.notify_when_newer(parent, config) end)
    end

    :ok
  end

  defp animation_cancel(nil), do: false
  defp animation_cancel(timer_ref), do: Process.cancel_timer(timer_ref)

  defp message_width(width), do: max(width - 14, 16)
end
