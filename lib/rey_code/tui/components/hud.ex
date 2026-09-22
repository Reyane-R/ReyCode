defmodule ReyCode.TUI.Components.HUD do
  @moduledoc "Responsive cyberpunk chrome and bounded, truthful Session instrumentation."

  use Breeze.Component

  alias ReyCode.TUI.{Activity, Blackwall, Effects}

  @rail_width_count 30
  @rail_min_width_count 120
  @rail_min_height_count 28
  @max_tool_rows_count 10
  @logo """
  █▀▀▄ █▀▀▀ █   █ ▄▀▀▀ █▀▀█ █▀▀▄ █▀▀▀
  █▄▄▀ █▄▄   ▀█▀  █    █  █ █  █ █▄▄
  █  █ █▄▄▄   █   ▀▄▄▄ █▄▄█ █▄▄▀ █▄▄▄
  """

  @doc "The rail is reserved only when the transcript retains a useful viewport."
  @spec rail_width(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def rail_width(width, height)
      when width >= @rail_min_width_count and height >= @rail_min_height_count,
      do: @rail_width_count

  def rail_width(_width, _height), do: 0

  @doc "The block-letter wordmark, with a plain spelling for basic terminals."
  @spec wordmark(boolean()) :: String.t()
  def wordmark(true), do: "R E Y C O D E //"
  def wordmark(_ascii), do: @logo

  @doc "Decorative glyphs share the terminal's ASCII policy."
  def glyph(:corner, true), do: "/"
  def glyph(:corner, _ascii), do: "╱"
  def glyph(:vertical, true), do: "|"
  def glyph(:vertical, _ascii), do: "│"
  def glyph(:connection, true), do: "--"
  def glyph(:connection, _ascii), do: "──"

  @doc "Cut-corner terminal frame, with an ASCII rendering for basic terminals."
  def frame(true) do
    BackBreeze.Border.custom(%{
      top: "-",
      bottom: "-",
      left: "|",
      right: "|",
      top_left: "/",
      top_right: "\\",
      bottom_left: "\\",
      bottom_right: "/"
    })
  end

  def frame(_ascii) do
    BackBreeze.Border.custom(%{
      top: "─",
      bottom: "─",
      left: "│",
      right: "│",
      top_left: "╱",
      top_right: "╲",
      bottom_left: "╲",
      bottom_right: "╱"
    })
  end

  attr :width, :integer, required: true
  attr :height, :integer, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, default: false
  attr :skip, :boolean, default: false
  attr :clip, :any, required: true

  def hero(assigns) do
    assigns = Map.put(assigns, :large?, assigns.width >= 72 and assigns.height >= 30)
    assigns = Map.put(assigns, :logo, wordmark(assigns.ascii))

    ~H"""
    <box :if={@large?} class="pt-1 w-full overflow-hidden">
      <box class="inline w-full">
        <box
          id="hud-logo"
          implicit={Effects}
          effect-kind={:logo}
          effect-enabled={@motion}
          effect-skip={@skip}
          effect-text={@logo}
          effect-clip={@clip}
          class="w-42 h-3 bg text-identity font-bold"
        >
          {@logo}
        </box>
        <box class="pl-3 w-full">
          <box class="text-primary font-bold">TERMINAL // ORCHESTRATION</box>
          <box class="text-muted">AT THE EDGE OF THE BLACKWALL</box>
          <box class="text-secondary">HUMAN + MACHINE</box>
        </box>
      </box>
      <box class="inline w-full pt-1">
        <box class="text-identity">{glyph(:corner, @ascii)} REYCODE </box>
        <.scan
          id="home-scan"
          width={min(@width - 30, 96)}
          motion={@motion}
          ascii={@ascii}
          class="text-boundary"
          clip={@clip}
        />
        <box class="text-muted"> // WORKBENCH</box>
      </box>
    </box>
    """
  end

  attr :id, :string, required: true
  attr :wall, :map, required: true
  attr :width, :integer, default: 24
  attr :rows, :integer, default: 1
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, default: false
  attr :clip, :any, required: true

  def boundary(assigns) do
    ~H"""
    <box
      id={@id}
      implicit={Effects}
      effect-kind={:blackwall}
      effect-phase={@wall.phase}
      effect-started-ms={@wall.started_ms}
      effect-identity={{@wall.session_id, @wall.work_id, @wall.phase, @wall.started_ms}}
      effect-enabled={@motion == true and Blackwall.animated?(@wall)}
      effect-width={@width}
      effect-rows={@rows}
      effect-ascii={@ascii}
      effect-clip={@clip}
      class={"bg-surface overflow-hidden text-" <> Blackwall.color(@wall)}
      style={%{width: max(@width, 1), height: @rows}}
    >
    </box>
    """
  end

  attr :id, :string, required: true
  attr :width, :integer, default: 24
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, default: false
  attr :kind, :atom, default: :scanner
  attr :identity, :any, default: nil
  attr :class, :string, default: "bg-surface text-primary"
  attr :clip, :any, default: {0, 0, 0, 0}

  def scan(assigns) do
    ~H"""
    <box
      id={@id}
      implicit={Effects}
      effect-kind={@kind}
      effect-enabled={@motion}
      effect-ascii={@ascii}
      effect-width={@width}
      effect-identity={@identity}
      effect-clip={@clip}
      class={"h-1 bg-surface overflow-hidden " <> @class}
      style={%{width: max(@width, 1)}}
    >
    </box>
    """
  end

  attr :session, :map, required: true
  attr :motion, :boolean, default: false
  attr :ascii, :boolean, default: false
  attr :clip, :any, required: true

  def home_rail(assigns) do
    assigns =
      Map.put(assigns, :deck, [
        {"/agent", "Create teammate"},
        {"/task", "Delegate work"},
        {"/resume", "Session archive"}
      ])

    ~H"""
    <box class="w-30 h-full bg-surface border-l px-2 overflow-hidden">
      <box class="pt-1 font-bold text-boundary">{glyph(:corner, @ascii)} BLACKWALL // INTERFACE</box>
      <box
        id="home-emblem"
        implicit={Effects}
        effect-kind={:emblem}
        effect-enabled={false}
        effect-ascii={@ascii}
        effect-clip={@clip}
        class="mt-1 h-7 w-24 bg-surface text-primary"
      >
      </box>
      <.scan
        id="home-carrier"
        width={24}
        kind={:blackwall}
        motion={false}
        ascii={@ascii}
        class="text-boundary"
        clip={@clip}
      />
      <box class="pt-1 text-muted">// WORKSPACE LINK</box>
      <box class="font-bold">{Path.basename(@session.workspace)}</box>
      <box class="pt-1 text-muted">// COMMAND DECK</box>
      <box :for={{command, label} <- @deck} class="inline w-full">
        <box class="w-9 text-primary">{command}</box>
        <box>{label}</box>
      </box>
    </box>
    """
  end

  attr :messages, :list, required: true
  attr :wall, :map, required: true
  attr :activity_frame, :string, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, required: true
  attr :clip, :any, required: true

  # The header already carries state, usage, and workspace. The rail shows
  # what it cannot: the newest tool runs, so files touched and commands run
  # stay visible while the transcript scrolls.
  def rail(assigns) do
    height = elem(assigns.clip, 3) - elem(assigns.clip, 1)
    limit = height |> Kernel.-(9) |> max(0) |> min(@max_tool_rows_count)
    rows = recent_tool_rows(assigns.messages)
    assigns = Map.merge(assigns, %{rows: Enum.take(rows, -limit), total: length(rows)})

    ~H"""
    <box class="w-30 h-full border-l bg-surface px-1 overflow-hidden">
      <box class="text-boundary font-bold">{glyph(:corner, @ascii)} BLACKWALL // HUD</box>
      <.boundary
        id="rail-scan"
        wall={@wall}
        width={26}
        rows={5}
        motion={@motion}
        ascii={@ascii}
        clip={@clip}
      />
      <box class="pt-1 text-muted">TOOL RUNS · {@total}</box>
      <box :if={@rows == []} class="text-muted">None yet</box>
      <box :for={row <- @rows} class="inline w-full h-1 overflow-hidden">
        <box class={"text-" <> Activity.color(row)}>{Activity.row_lead(row, @activity_frame)}</box>
        <box class="text-muted">{Activity.row_tail(row)}</box>
      </box>
      <box :if={@total > length(@rows)} class="pt-1 text-muted">Older in /runs</box>
    </box>
    """
  end

  defp recent_tool_rows(messages) do
    messages
    |> Enum.flat_map(&Map.get(&1, :execution_rows, []))
    |> Enum.filter(&(Map.get(&1, :kind) == :tool))
  end

  attr :term, :map, required: true

  def modal_chrome(assigns) do
    assigns =
      Map.put(assigns, :term, Map.get(assigns, :term) || assigns.__breeze_caller_assigns__)

    ~H"""
    <box
      :if={@term.modal not in [nil, :slash, :operator_question]}
      class="h-1 bg-surface text-boundary overflow-hidden"
      style={%{position: :fixed, top: 0, left: 0, width: @term.breeze.terminal.width, layer: 60}}
    >
      <box class="inline w-full">
        <box class="font-bold text-identity">
          {glyph(:corner, @term.animation_style == :ascii)} REYCODE //
        </box>
        <.scan
          id="modal-scan"
          width={min(max(@term.breeze.terminal.width - 14, 1), 96)}
          identity={@term.modal}
          motion={not @term.config.tui.reduced_motion?}
          ascii={@term.animation_style == :ascii}
          class="text-boundary"
          clip={{0, 0, @term.breeze.terminal.width, 1}}
        />
      </box>
    </box>
    """
  end
end
