defmodule ReyCode.TUI.State do
  @moduledoc "Shared terminal state initialization and projection updates for the root view."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.{Catalog, Presentation}

  alias ReyCode.TUI.{
    AgentProfile,
    Delegation,
    ModelPicker,
    SessionPicker,
    Settings,
    SlashPalette,
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

    {:ok,
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
       notice: nil
     )}
  end

  @doc "Adds transient values consumed by the extracted renderer."
  @spec prepare_render(map()) :: map()
  def prepare_render(assigns) do
    width = assigns.breeze.terminal.width
    height = assigns.breeze.terminal.height
    room = assigns.projection.rooms[assigns.selected_room_id]

    Component.assign(assigns,
      room: room,
      rooms: Enum.map(assigns.projection.room_order, &assigns.projection.rooms[&1]),
      messages: room_messages(room, assigns.projection),
      draft: Map.get(assigns.drafts, assigns.selected_room_id, ""),
      git_branch: git_branch(room && room.workspace),
      token_label: token_label(room, assigns.projection, assigns.config),
      elapsed_seconds: running_elapsed(room, assigns.projection),
      message_width: message_width(width),
      timeline_id: timeline_id(room.id),
      recent_session_rows: recent_session_rows(assigns),
      slash_rows: slash_rows(assigns.slash, height),
      slash_style: SlashPalette.style(width, height, assigns.slash),
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

  defp running_elapsed(room, projection) do
    with turn_id when not is_nil(turn_id) <- room && room.active_turn_id,
         %{status: :running, created_at: created_at} <- projection.turns[turn_id] do
      case DateTime.from_iso8601(created_at) do
        {:ok, started, _offset} ->
          max(DateTime.to_unix(DateTime.utc_now()) - DateTime.to_unix(started), 0)

        _other ->
          nil
      end
    else
      _other -> nil
    end
  end

  defp slash_rows(nil, _height), do: []

  defp slash_rows(slash, height) do
    Enum.map(SlashPalette.rows(slash, height), fn {command, index} ->
      %{
        command: command.command,
        description: command.description,
        option_class: SlashPalette.option_class(index, slash.index),
        command_class: SlashPalette.command_class(index, slash.index),
        description_class: SlashPalette.description_class(index, slash.index)
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

      if term.assigns.modal == :settings, do: Settings.reconcile_options(term), else: term
    end
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

        {:ok,
         Component.assign(term,
           selected_room_id: session_id,
           projection: projection,
           drafts: drafts,
           home: false,
           notice: nil
         )}

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

    Component.assign(term,
      selected_room_id: source_session_id,
      home: true,
      drafts: drafts,
      modal: nil,
      notice: nil
    )
  end

  @doc "Returns the selected session timeline element ID."
  @spec timeline_id(term()) :: String.t()
  def timeline_id(session_id), do: "timeline-#{session_id}"

  defp room_messages(nil, _projection), do: []

  defp room_messages(room, projection) do
    room.message_order
    |> Enum.reverse()
    |> Enum.map(fn message_id ->
      message = projection.messages[message_id]

      message
      |> Map.put(:invocation, projection.invocations[message.invocation_id])
      |> Map.put(
        :tool_run_rows,
        tool_run_rows(projection.invocations[message.invocation_id])
      )
      |> Map.put(:note_rows, note_rows(projection.invocations[message.invocation_id]))
      |> Map.put(:turn, projection.turns[message.turn_id])
    end)
  end

  defp tool_run_rows(invocation) when is_map(invocation) do
    invocation.tool_run_order
    |> List.wrap()
    |> Enum.flat_map(fn run_id ->
      case Map.get(invocation.tool_runs || %{}, run_id) do
        nil -> []
        run -> [tool_run_row(run)]
      end
    end)
  end

  defp tool_run_rows(_invocation), do: []

  # Activity trail shown beside the reply: newest lines win, older ones
  # collapse into a "+k more" marker rendered by the timeline.
  defp note_rows(invocation) when is_map(invocation),
    do: invocation |> Map.get(:notes, []) |> List.wrap()

  defp note_rows(_invocation), do: []

  defp tool_run_row(run) do
    %{
      tool: to_string(run.tool),
      target: argument_summary(run.arguments),
      status: run_status_label(run)
    }
  end

  defp run_status_label(%{status: :completed, result: %{"ok" => true}}), do: "ok"

  defp run_status_label(%{status: :completed, result: %{"ok" => false, "error" => error}}),
    do: "failed · " <> truncate_text(inspect(error), 40)

  defp run_status_label(%{status: status}) when status in [:completed, :failed],
    do: Atom.to_string(status)

  defp run_status_label(%{status: :denied}), do: "denied"
  defp run_status_label(%{status: :interrupted}), do: "interrupted"
  defp run_status_label(%{status: :awaiting_approval}), do: "awaiting approval"
  defp run_status_label(%{status: :running}), do: "running"
  defp run_status_label(_run), do: ""

  defp argument_summary(arguments) when is_map(arguments) do
    cond do
      is_binary(arguments["path"]) -> arguments["path"]
      is_binary(arguments["command"]) -> truncate_text(arguments["command"], 48)
      is_binary(arguments["pattern"]) -> arguments["pattern"]
      true -> first_argument(arguments)
    end
  end

  defp argument_summary(_arguments), do: ""

  defp first_argument(arguments) do
    case Enum.at(Map.to_list(arguments), 0) do
      nil -> ""
      {key, value} -> "#{key}=#{truncate_text(to_string(value), 40)}"
    end
  end

  defp truncate_text(value, limit) do
    if String.length(value) <= limit, do: value, else: String.slice(value, 0, limit - 1) <> "…"
  end

  defp message_width(width), do: max(width - 14, 16)
end
