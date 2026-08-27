defmodule ReyCode.TUI.State do
  @moduledoc "Shared terminal state initialization and projection updates for the root view."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.{Catalog, Presentation}

  alias ReyCode.TUI.{
    Activity,
    AgentProfile,
    AnimationClock,
    Delegation,
    ModelPicker,
    SessionPicker,
    Settings,
    SlashPalette,
    Spinner,
    TimeAgo,
    ToolReview
  }

  @doc "Subscribes the root view and initializes its stable assign shapes."
  @spec mount(keyword(), map()) :: {:ok, map()}
  def mount(opts, term) do
    engine = Keyword.get(opts, :engine, Engine)
    provider_catalog = Keyword.get(opts, :provider_catalog, Catalog)
    config = Keyword.get_lazy(opts, :config, &ReyCode.RuntimeConfig.fresh/0)
    projection = Engine.subscribe(engine)
    catalog_snapshot = Catalog.subscribe(provider_catalog)

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
        projection: projection,
        selected_room_id: List.last(projection.room_order),
        drafts: %{},
        mode: :direct,
        home: true,
        modal: nil,
        cancel_turn_id: nil,
        agent_profile: AgentProfile.initial(),
        delegation: Delegation.initial(),
        tool_review: ToolReview.initial(),
        slash: nil,
        model_picker: ModelPicker.initial(),
        session_picker: SessionPicker.initial(),
        settings: Settings.initial(),
        workspace_preview_path: nil,
        animation_clock: clock,
        animation_now_ms: now_ms,
        animation_style: Keyword.get(opts, :animation_style, Spinner.style()),
        notice: nil
      )

    {:ok, reconcile_animation(term, now_ms)}
  end

  @doc "Adds transient values consumed by the extracted renderer."
  @spec prepare_render(map()) :: map()
  def prepare_render(assigns) do
    width = assigns.breeze.terminal.width
    height = assigns.breeze.terminal.height
    room = assigns.projection.rooms[assigns.selected_room_id]
    message_width = message_width(width)
    target_graphemes = target_graphemes(width)

    activity =
      Activity.present(
        assigns.selected_room_id,
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

    Component.assign(assigns,
      room: room,
      rooms: Enum.map(assigns.projection.room_order, &assigns.projection.rooms[&1]),
      messages:
        room_messages(
          room,
          assigns.projection,
          activity,
          assigns.animation_now_ms,
          target_graphemes
        ),
      activity: activity,
      activity_frame: frame,
      draft: Map.get(assigns.drafts, assigns.selected_room_id, ""),
      git_branch: git_branch(room && room.workspace),
      token_label: token_label(room, assigns.projection, assigns.config),
      message_width: message_width,
      timeline_id: timeline_id(room.id),
      recent_session_rows: recent_session_rows(assigns),
      slash_rows: slash_rows(assigns, height),
      slash_style: SlashPalette.style(width, height, assigns),
      tool_review_options: ToolReview.options()
    )
  end

  defp recent_session_rows(assigns) do
    assigns.projection.room_order
    |> Enum.reverse()
    |> Enum.map(&assigns.projection.rooms[&1])
    |> Enum.filter(&(&1.message_order != []))
    |> Enum.take(3)
    |> Enum.map(fn session ->
      %{
        title: session.title,
        meta: TimeAgo.format(session.created_at) <> "  ·  " <> Path.basename(session.workspace)
      }
    end)
  end

  defp git_branch(nil), do: nil

  defp git_branch(workspace) do
    case File.read(Path.join(workspace, ".git/HEAD")) do
      {:ok, "ref: refs/heads/" <> branch} -> "⑂ " <> String.trim(branch)
      {:ok, _detached} -> "⑂ detached"
      _other -> nil
    end
  end

  defp token_label(room, projection, config) do
    tokens = token_usage(room, projection)

    "#{meter_bar(room, projection, config)}  tok #{format_tokens(tokens)}/#{format_tokens(config.orchestration.context_budget_tokens)}"
  end

  defp meter_bar(room, projection, config) do
    used = token_usage(room, projection)
    budget = config.orchestration.context_budget_tokens
    ratio = if budget > 0, do: used / budget, else: 0.0
    cells = 5
    filled = round(ratio * cells) |> min(cells) |> max(0)
    String.duplicate("■", filled) <> String.duplicate("□", cells - filled)
  end

  defp token_usage(room, projection) do
    Enum.reduce(projection.invocations, 0, fn {_id, invocation}, acc ->
      if invocation.room_id == room.id,
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
    Enum.map(SlashPalette.rows(assigns, height), fn {candidate, index} ->
      %{
        command: candidate.label,
        description: candidate.detail,
        option_class: SlashPalette.option_class(index, assigns.slash.index),
        command_class: SlashPalette.command_class(candidate.kind, index, assigns.slash.index),
        description_class: SlashPalette.description_class(index, assigns.slash.index)
      }
    end)
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
        selected_room_id =
          if Map.has_key?(projection.rooms, term.assigns.selected_room_id) do
            term.assigns.selected_room_id
          else
            List.last(projection.room_order)
          end

        Component.assign(term, projection: projection, selected_room_id: selected_room_id)
      end

    reconcile_animation(term)
  end

  @doc "Applies a catalog snapshot unless its generation is not newer."
  @spec providers_updated(map(), ReyCode.Provider.Catalog.Snapshot.t()) :: map()
  def providers_updated(term, %{generation: generation} = snapshot) do
    if generation <= term.assigns.providers_generation do
      term
    else
      notice =
        if term.assigns.notice == Presentation.refresh_notice(),
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
    |> Component.assign(selected_room_id: session_id, home: home?)
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
    drafts = Map.put(term.assigns.drafts, term.assigns.selected_room_id, value)
    Component.assign(term, drafts: drafts)
  end

  @doc "Creates and selects a fresh titled durable session for the session's first input."
  @spec ensure_session(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_session(%{assigns: %{home: true}} = term, first_input) do
    case Engine.create_session(
           term.assigns.selected_room_id,
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
    source_session_id = List.last(term.assigns.projection.room_order)
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

  defp room_messages(nil, _projection, _activity, _now_ms, _target_graphemes), do: []

  defp room_messages(room, projection, activity, now_ms, target_graphemes) do
    room.message_order
    |> Enum.reverse()
    |> Enum.map(fn message_id ->
      message = projection.messages[message_id]
      invocation = projection.invocations[message.invocation_id]

      message
      |> Map.put(:invocation, invocation)
      |> Map.put(:activity, Activity.invocation(activity, message.invocation_id))
      |> Map.put(
        :tool_run_rows,
        tool_run_rows(invocation, room.workspace, now_ms, target_graphemes)
      )
      |> Map.put(:note_rows, note_rows(invocation))
      |> Map.put(:turn, projection.turns[message.turn_id])
    end)
  end

  defp tool_run_rows(invocation, workspace, now_ms, target_graphemes)
       when is_map(invocation) do
    invocation.tool_run_order
    |> List.wrap()
    |> Enum.flat_map(fn run_id ->
      case Map.get(invocation.tool_runs || %{}, run_id) do
        nil ->
          []

        run ->
          run = Map.put_new(run, :id, run_id)
          [Activity.tool(run, workspace, now_ms, target_graphemes: target_graphemes)]
      end
    end)
  end

  defp tool_run_rows(_invocation, _workspace, _now_ms, _target_graphemes), do: []

  # Activity trail shown beside the reply: newest lines win, older ones
  # collapse into a "+k more" marker rendered by the timeline.
  defp note_rows(%{notes: notes}) when is_list(notes), do: notes

  defp note_rows(_invocation), do: []

  defp current_activity(term, now_ms) do
    Activity.present(
      term.assigns.selected_room_id,
      term.assigns.projection,
      term.assigns.providers,
      now_ms,
      target_graphemes: 48
    )
  end

  defp target_graphemes(width), do: width |> Kernel.-(34) |> max(16) |> min(72)

  defp animation_schedule(token, delay_ms),
    do: Process.send_after(self(), {:activity_tick, token}, delay_ms)

  defp animation_cancel(nil), do: false
  defp animation_cancel(timer_ref), do: Process.cancel_timer(timer_ref)

  defp message_width(width), do: max(width - 14, 16)
end
